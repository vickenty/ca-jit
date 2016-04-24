use strict;
use warnings;
use Test::More;
use Test::LeakTrace;

package Dummy {
    use strict;
    use warnings;
    use parent "Class::Accessor::JIT";

    sub new { bless {}, shift }
}


isa_ok "Dummy", "Class::Accessor::JIT";
isa_ok "Dummy", "Class::Accessor";

can_ok "Dummy", "follow_best_practice";
can_ok "Dummy", "mk_accessors";

Dummy->mk_accessors("foo");

my $dummy = Dummy->new();

can_ok $dummy, "foo";
ok !defined $dummy->foo(), "foo works";
ok !exists $dummy->{foo}, "{foo} not exists";

is $dummy->foo(42), 42, "foo sets integer";
is $dummy->{foo}, 42, "{foo} matches integer";
is $dummy->foo(), 42, "foo gets integer";

is_deeply $dummy->foo(1..10), [ 1..10 ], "foo sets array";
is_deeply $dummy->{foo}, [ 1..10 ], "{foo} matches array";
is_deeply $dummy->foo(), [ 1..10 ], "foo gets array";

my $leaky = Dummy->new();

no_leaks_ok { $leaky->foo(); };
no_leaks_ok { $leaky->foo(42); };
no_leaks_ok { $leaky->foo(); };
no_leaks_ok { $leaky->foo("bar"); };
no_leaks_ok { $leaky->foo(); };
no_leaks_ok { $leaky->foo(1..10); };
no_leaks_ok { $leaky->foo(); };

done_testing;
