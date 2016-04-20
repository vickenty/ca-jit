package Class::Accessor::JIT;
use strict;
use warnings;

use parent "Class::Accessor";
use Class::Accessor::JIT::Builder;

our $VERSION = "0.01";

sub make_accessor {
    my ($self, $field) = @_;

    my $builder = Class::Accessor::JIT::Builder->new();

    return $builder->build($field);
}

1;
