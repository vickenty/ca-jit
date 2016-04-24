package Class::Accessor::JIT::Builder;
use strict;
use warnings;

use GCCJIT ":all";
use GCCJIT::Context;
use Ouroboros ":all";
use Ouroboros::Spec;
use Hash::Util qw/hash_value/;
use Config;

use constant {
    SYMBOL_NAME => "xs_accessor",
};

my %TYPEMAP = (
    "void" => GCC_JIT_TYPE_VOID,
    "PTHX" => GCC_JIT_TYPE_VOID_PTR,
    "SV" => GCC_JIT_TYPE_VOID,
    "SV" => GCC_JIT_TYPE_VOID,
    "AV" => GCC_JIT_TYPE_VOID,
    "HV" => GCC_JIT_TYPE_VOID,
    "HE" => GCC_JIT_TYPE_VOID,
    "CV" => GCC_JIT_TYPE_VOID,
    "int" => GCC_JIT_TYPE_INT,
    "char" => GCC_JIT_TYPE_CHAR,
    "const char*" => GCC_JIT_TYPE_CONST_CHAR_PTR,
    "SSize_t" => [ $Config{sizesize}, 1 ],
    "STRLEN" => [ $Config{sizesize}, 0 ],
    "U8" => [ 1, 0 ],
    "U32" => [ 4, 0 ],
    "I8" => [ 1, 1 ],
    "I32" => [ 4, 1 ],
    "ouroboros_stack_t" => GCC_JIT_TYPE_VOID,
);

my %FN_SIGS = (
    hv_fetch_ent => [ "HE*", "PTHX", "HV*", "SV*", "I32", "U32" ],
    hv_store_ent => [ "HE*", "PTHX", "HV*", "SV*", "SV*", "U32" ],
    newSVsv => [ "SV*", "PTHX", "SV*" ],
    newAV => [ "AV*", "PTHX" ],
    newRV_noinc => [ "SV*", "PTHX", "SV*" ],
    av_fill => [ "void", "PTHX", "AV*", "SSize_t" ],
    av_store => [ "SV**", "PTHX", "AV*", "SSize_t", "SV*" ],
    map { $_->{name} => [ $_->{type}, "PTHX", @{$_->{params}} ] }
    @{$Ouroboros::Spec::SPEC{fn}}
);

sub new {
    my ($class, @names) = @_;

    return bless {
        ctx => GCCJIT::Context->acquire(),
        names => \@names,
    }, $class;
}

sub type {
    my ($self, $ctype) = @_;

    return () if $ctype eq "PTHX" && !$Config{usemultiplicity};

    return $self->{typemap}{$ctype} //= do {
        my $base;

        if (defined (my $spec = $TYPEMAP{$ctype})) {
            ref $spec ? $self->{ctx}->get_int_type(@$spec) : $self->{ctx}->get_type($spec);
        }
        elsif (($base) = $ctype =~ /^const (.*)/) {
            $self->type($base)->get_const();
        }
        elsif (($base) = $ctype =~ /^(.*)\*$/) {
            $self->type($base)->get_pointer();
        }
        else {
            die "unknown type $ctype\n";
        }
    };
}

sub func_ptr {
    my ($self, $name) = @_;
    if ($name =~ /^ouroboros_/) {
        return Ouroboros->can("${name}_ptr")->();
    } else {
        return DynaLoader::dl_find_symbol(0, "Perl_$name");
    }
}

sub func {
    my ($self, $name) = @_;

    return $self->{fn_ptr}{$name} //= do {
        my $sig = $FN_SIGS{$name} or die "unknown function $name";
        my ($type, @params) = map $self->type($_), @$sig;

        my $ptr = $self->func_ptr($name) // die "unable to find function $name";

        $self->{ctx}->new_rvalue_from_ptr(
            $self->{ctx}->new_function_ptr_type(undef, $type, \@params, 0),
            $ptr,
        );
    };
}

sub _as_rvalue {
    map { ref $_ eq "gcc_jit_rvaluePtr" ? $_ : $_->as_rvalue } @_
}

sub call {
    my ($self, $name, @args) = @_;

    my $fn_ptr = $self->func($name);
    return $self->{ctx}->new_call_through_ptr(undef, $fn_ptr, [ _as_rvalue(@args) ]) // die "call error";
}

sub pthx {
    my ($self) = @_;

    my ($type) = $self->type("PTHX");

    if (defined $type) {
        return $self->{pthx} //= $self->{ctx}->new_param(undef, $type, "my_perl");
    } else {
        return ();
    }
}

sub athx {
    my ($self) = @_;
    defined $self->{pthx} ? $self->{pthx} : ()
}

sub init_function {
    my ($self) = @_;

    my $cv = $self->{ctx}->new_param(undef, $self->type("CV*"), "cv");

    $self->{func} = $self->{ctx}->new_function(undef,
        GCC_JIT_FUNCTION_EXPORTED,
        $self->type("void"),
        SYMBOL_NAME,
        [ $self->pthx, $cv ],
        0,
    );


    my $stack_t = $self->{ctx}->new_array_type(undef, $self->type("U8"), $Ouroboros::SIZE_OF{ouroboros_stack_t});
    $self->{stack} = $self->{ctx}->new_cast(
        undef,
        $self->{func}->new_local(undef, $stack_t, "stack")->get_address(undef),
        $self->type("ouroboros_stack_t*"));

    my $init = $self->{func}->new_block("init");
    $init->add_eval(undef, $self->call("ouroboros_stack_init", $self->athx, $self->{stack}));

    $self->{values}{items} = $self->{func}->new_local(undef, $self->type("int"), "items");
    $init->add_assignment(undef,
        $self->{values}{items},
        $self->call("ouroboros_stack_items", $self->athx, $self->{stack}));

    return $init;
}

sub binop {
    my ($self, $op, $type, $l, $r) = @_;

    return $self->{ctx}->new_binary_op(undef, $op, $type, _as_rvalue($l, $r));
}

sub comp {
    my ($self, $op, $l, $r) = @_;

    return $self->{ctx}->new_comparison(undef, $op, _as_rvalue($l, $r));
}

sub cond {
    my ($self, $block, $cond) = @_;

    my $then = $self->{func}->new_block("block" . ++$self->{blockid});
    my $else = $self->{func}->new_block("block" . ++$self->{blockid});

    $block->end_with_conditional(undef, $cond, $then, $else);

    return ($then, $else);
}

sub zero {
    my ($self, $type) = @_;
    return $self->{ctx}->zero($self->type($type));
}

sub null {
    my ($self, $type) = @_;
    return $self->{ctx}->null($self->type($type));
}

sub one {
    my ($self, $type) = @_;
    return $self->{ctx}->one($self->type($type));
}

sub return {
    my ($self, $block, @values) = @_;
    $block->add_eval(undef, $self->call("ouroboros_stack_prepush", $self->athx, $self->{stack}));

    $block->add_eval(undef, $self->call("ouroboros_stack_xpush_sv", $self->athx, $self->{stack}, $_))
        foreach @values;

    $block->add_eval(undef, $self->call("ouroboros_stack_putback", $self->athx, $self->{stack}));
    $block->end_with_void_return(undef);
}


sub check_for_obj {
    my ($self, $block) = @_;

    my $comp = $self->comp(GCC_JIT_COMPARISON_GT, $self->{values}{items}, $self->zero("int"));

    my ($then, $else) = $self->cond($block, $comp);

    $self->return($else);

    return $self->check_for_obj_ref($then);
}

sub check_for_obj_ref {
    my ($self, $block) = @_;

    my $obj = $self->call("ouroboros_stack_fetch", $self->athx, $self->{stack}, $self->zero("SSize_t"));
    my $rok = $self->call("ouroboros_sv_rok", $self->athx, $obj);
    my $comp = $self->comp(GCC_JIT_COMPARISON_NE, $rok, $self->zero("U32"));

    my ($then, $else) = $self->cond($block, $comp);

    $self->return($else);

    $self->{locals}{self} = $self->{func}->new_local(undef, $self->type("HV*"), "hv");
    $then->add_assignment(undef, $self->{locals}{self}, $self->call("ouroboros_sv_rv", $self->athx, $obj));

    return $then;
}

sub check_for_arg {
    my ($self, $block) = @_;

    my $one = $self->{ctx}->one($self->type("int"));
    my $comp = $self->comp(GCC_JIT_COMPARISON_EQ, $self->{values}{items}, $one);

    return $self->cond($block, $comp);
}

sub build_getter {
    my ($self, $block, $name, $hash) = @_;

    my $he = $self->call("hv_fetch_ent", $self->athx, $self->{locals}{self}, $name, $self->zero("I32"), $hash);
    my $comp = $self->comp(GCC_JIT_COMPARISON_EQ, $he, $self->null("HE*"));

    my ($null, $okay) = $self->cond($block, $comp);

    $self->return($null);
    $self->return($okay, $self->call("ouroboros_he_val", $self->athx, $he));
}

sub build_store {
    my ($self, $value, $name, $hash) = @_;

    my $block = $self->{func}->new_block("store");

    $block->add_eval(undef,
        $self->call("hv_store_ent", $self->athx, $self->{locals}{self}, $name, $value, $hash));

    return $block;
}

sub build_setter_one {
    my ($self, $block, $val, $next) = @_;

    $block->add_assignment(undef, $val,
        $self->call("newSVsv", $self->athx,
            $self->call("ouroboros_stack_fetch", $self->athx, $self->{stack}, $self->one("SSize_t"))));

    $block->end_with_jump(undef, $next);
}

sub build_setter_many {
    my ($self, $block, $val, $next) = @_;

    my $loop = $self->{func}->new_block("loop");

    my $array = $self->{func}->new_local(undef, $self->type("AV*"), "array");
    my $fill = $self->{func}->new_local(undef, $self->type("SSize_t"), "fill");
    my $two = $self->{ctx}->new_rvalue_from_int($self->type("int"), 2);

    $block->add_assignment(undef, $array, $self->call("newAV", $self->athx));
    $block->add_assignment(undef, $val, $self->call("newRV_noinc", $self->athx, $array));
    $block->add_assignment(undef, $fill, $self->binop(GCC_JIT_BINARY_OP_MINUS, $self->type("SSize_t"), $self->{values}{items}, $two));
    $block->add_eval(undef, $self->call("av_fill", $self->athx, $array, $fill));

    $block->end_with_jump(undef, $loop);

    $loop->add_eval(undef,
        $self->call("av_store", $self->athx, $array, $fill,
            $self->call("newSVsv", $self->athx,
                $self->call("ouroboros_stack_fetch", $self->athx, $self->{stack},
                    $self->binop(GCC_JIT_BINARY_OP_PLUS, $self->type("SSize_t"), $fill, $self->one("SSize_t"))))));

    $loop->add_assignment_op(undef, $fill, GCC_JIT_BINARY_OP_MINUS, $self->one("SSize_t"));

    my $comp = $self->comp(GCC_JIT_COMPARISON_GE, $fill, $self->zero("SSize_t"));

    $loop->end_with_conditional(undef, $comp, $loop, $next);
}

sub build_setter {
    my ($self, $block, $name, $hash) = @_;

    my $val = $self->{func}->new_local(undef, $self->type("SV*"), "val");
    my $set = $self->build_store($val, $name, $hash);

    my $two = $self->{ctx}->new_rvalue_from_int($self->type("int"), 2);
    my $comp = $self->comp(GCC_JIT_COMPARISON_EQ, $self->{values}{items}, $two);

    my ($one, $many) = $self->cond($block, $comp);

    $self->build_setter_one($one, $val, $set);
    $self->build_setter_many($many, $val, $set);

    $self->return($set, $val);
}

my @keepalive;
sub install {
    my ($self) = @_;
    my $result = $self->{ctx}->compile();
    my $code = $result->get_code(SYMBOL_NAME) or die "compilation failed";
    push @keepalive, $result;
    return DynaLoader::dl_install_xsub("Class::Accessor::JIT::xs_accessor", $code);
}

sub build {
    my ($self, $field_name) = @_;

    push @keepalive, \$field_name;

    $self->{ctx}->set_int_option(GCC_JIT_INT_OPTION_OPTIMIZATION_LEVEL, 3);
    #$self->{ctx}->set_bool_option(GCC_JIT_BOOL_OPTION_DEBUGINFO, 1);
    #$self->{ctx}->set_bool_option(GCC_JIT_BOOL_OPTION_KEEP_INTERMEDIATES, 1);

    my $init = $self->init_function();

    my $body = $self->check_for_obj($init);
    my ($get, $set) = $self->check_for_arg($body);

    my $name = $self->{ctx}->new_rvalue_from_ptr($self->type("SV*"), int \$field_name);
    my $hash = $self->{ctx}->new_rvalue_from_int($self->type("U32"), hash_value($field_name));

    $self->build_getter($get, $name, $hash);
    $self->build_setter($set, $name, $hash);

    return $self->install();
}

1;
