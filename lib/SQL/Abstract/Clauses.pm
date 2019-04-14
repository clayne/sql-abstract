package SQL::Abstract::Clauses;

use strict;
use warnings;
use if $] < '5.010', 'MRO::Compat';
use mro 'c3';
use base 'SQL::Abstract';

BEGIN { *puke = \&SQL::Abstract::puke }

sub new {
  shift->next::method(@_)->register_defaults
}

sub register_defaults {
  my ($self) = @_;
  $self->{clauses_of}{select} = [ qw(select from where order_by) ];
  $self->{expand}{select} = sub { shift->_expand_statement(@_) };
  $self->{render}{select} = sub { shift->_render_statement(select => @_) };
  $self->{expand_clause}{"select.$_"} = "_expand_select_clause_$_"
    for @{$self->{clauses_of}{select}};
  $self->{clauses_of}{update} = [ qw(target set where returning) ];
  $self->{expand}{update} = sub { shift->_expand_statement(@_) };
  $self->{render}{update} = sub { shift->_render_statement(update => @_) };
  $self->{expand_clause}{"update.$_"} = "_expand_update_clause_$_"
    for @{$self->{clauses_of}{update}};
  $self->{expand_clause}{'update.update'} = '_expand_update_clause_target';
  $self->{render_clause}{'update.target'} = sub {
    my ($self, $target) = @_;
    my ($sql, @bind) = $self->render_aqt($target);
    ($self->_sqlcase('update ').$sql, @bind);
  };
  $self->{clauses_of}{delete} = [ qw(target where returning) ];
  $self->{expand}{delete} = sub { shift->_expand_statement(@_) };
  $self->{render}{delete} = sub { shift->_render_statement(delete => @_) };
  $self->{expand_clause}{"delete.$_"} = "_expand_delete_clause_$_"
    for @{$self->{clauses_of}{delete}};
  $self->{expand_clause}{"delete.from"} = '_expand_delete_clause_target';
  $self->{render_clause}{'delete.target'} = sub {
    my ($self, $from) = @_;
    my ($sql, @bind) = $self->render_aqt($from);
    ($self->_sqlcase('delete from ').$sql, @bind);
  };
  $self->{clauses_of}{insert} = [
    'target', 'fields', 'from', 'returning'
  ];
  $self->{expand}{insert} = sub { shift->_expand_statement(@_) };
  $self->{render}{insert} = sub { shift->_render_statement(insert => @_) };
  $self->{expand_clause}{'insert.into'} = '_expand_insert_clause_target';
  $self->{expand_clause}{'insert.target'} = '_expand_insert_clause_target';
  $self->{expand_clause}{'insert.fields'} = sub {
    return +{ -row => [
      shift->_expand_maybe_list_expr(@_, -ident)
    ] } if ref($_[1]) eq 'ARRAY';
    return $_[1]; # should maybe still expand somewhat?
  };
  $self->{expand_clause}{'insert.values'} = '_expand_insert_clause_values';
  $self->{expand_clause}{'insert.returning'} = sub {
    shift->_expand_maybe_list_expr(@_, -ident);
  };
  $self->{render_clause}{'insert.fields'} = sub {
    return $_[0]->render_aqt($_[1]);
  };
  $self->{render_clause}{'insert.target'} = sub {
    my ($self, $from) = @_;
    my ($sql, @bind) = $self->render_aqt($from);
    ($self->_sqlcase('insert into ').$sql, @bind);
  };
  $self->{render_clause}{'insert.from'} = sub {
    return $_[0]->render_aqt($_[1]);
  };
  return $self;
}

sub _expand_select_clause_select {
  my ($self, $select) = @_;
  +(select => $self->_expand_maybe_list_expr($select, -ident));
}

sub _expand_select_clause_from {
  my ($self, $from) = @_;
  +(from => $self->_expand_maybe_list_expr($from, -ident));
}

sub _expand_select_clause_where {
  my ($self, $where) = @_;
  +(where => $self->expand_expr($where));
}

sub _expand_select_clause_order_by {
  my ($self, $order_by) = @_;
  +(order_by => $self->_expand_order_by($order_by));
}

sub _expand_update_clause_target {
  my ($self, $target) = @_;
  +(target => $self->_expand_maybe_list_expr($target, -ident));
}

sub _expand_update_clause_set {
  return $_[1] if ref($_[1]) eq 'HASH' and ($_[1]->{-op}||[''])->[0] eq ',';
  +(set => shift->_expand_update_set_values(@_));
}

sub _expand_update_clause_where {
  +(where => shift->expand_expr(@_));
}

sub _expand_update_clause_returning {
  +(returning => shift->_expand_maybe_list_expr(@_, -ident));
}

sub _expand_delete_clause_target {
  +(target => shift->_expand_maybe_list_expr(@_, -ident));
}

sub _expand_delete_clause_where { +(where => shift->expand_expr(@_)); }

sub _expand_delete_clause_returning {
  +(returning => shift->_expand_maybe_list_expr(@_, -ident));
}

sub _expand_statement {
  my ($self, $type, $args) = @_;
  my $ec = $self->{expand_clause};
  return +{ "-${type}" => +{
    map {
      my $val = $args->{$_};
      if (defined($val) and my $exp = $ec->{"${type}.$_"}) {
        if ((my (@exp) = $self->$exp($val)) == 1) {
          ($_ => $exp[0])
        } else {
          @exp
        }
      } else {
        ($_ => $self->expand_expr($val))
      }
    } sort keys %$args
  } };
}

sub _render_statement {
  my ($self, $type, $args) = @_;
  my @parts;
  foreach my $clause (@{$self->{clauses_of}{$type}}) {
    next unless my $clause_expr = $args->{$clause};
    local $self->{convert_where} = $self->{convert} if $clause eq 'where';
    my ($sql) = my @part = do {
      if (my $rdr = $self->{render_clause}{"${type}.${clause}"}) {
        $self->$rdr($clause_expr);
      } else {
        my ($clause_sql, @bind) = $self->render_aqt($clause_expr);
        my $sql = join ' ',
          $self->_sqlcase(join ' ', split '_', $clause),
          $clause_sql;
        ($sql, @bind);
      }
    };
    next unless defined($sql) and length($sql);
    push @parts, \@part;
  }
  return $self->_join_parts(' ', @parts);
}

sub select {
  my ($self, @args) = @_;

  return $self->render_expr({ -select => $_[1] }) if ref($_[1]) eq 'HASH';

  my %clauses;
  @clauses{qw(from select where order_by)} = @args;

  # This oddity is to literalify since historically SQLA doesn't quote
  # a single identifier argument, so we convert it into a literal

  $clauses{select} = { -literal => [ $clauses{select}||'*' ] }
    unless ref($clauses{select});

  return $self->render_expr({ -select => \%clauses });
}

sub update {
  my ($self, $table, $set, $where, $options) = @_;

  return $self->render_expr({ -update => $_[1] }) if ref($_[1]) eq 'HASH';

  my %clauses;
  @clauses{qw(target set where)} = ($table, $set, $where);
  puke "Unsupported data type specified to \$sql->update"
    unless ref($clauses{set}) eq 'HASH';
  @clauses{keys %$options} = values %$options;
  return $self->render_expr({ -update => \%clauses });
}

sub delete {
  my ($self, $table, $where, $options) = @_;

  return $self->render_expr({ -delete => $_[1] }) if ref($_[1]) eq 'HASH';

  my %clauses = (target => $table, where => $where, %{$options||{}});
  return $self->render_expr({ -delete => \%clauses });
}

sub insert {
  my ($self, $table, $data, $options) = @_;

  return $self->render_expr({ -insert => $_[1] }) if ref($_[1]) eq 'HASH';

  my %clauses = (target => $table, values => $data, %{$options||{}});
  return $self->render_expr({ -insert => \%clauses });
}

sub _expand_insert_clause_target {
  +(target => shift->_expand_maybe_list_expr(@_, -ident));
}

sub _expand_insert_clause_values {
  my ($self, $data) = @_;
  if (ref($data) eq 'HASH' and (keys(%$data))[0] =~ /^-/) {
    return $self->expand_expr($data);
  }
  return $data if ref($data) eq 'HASH' and $data->{-row};
  my ($f_aqt, $v_aqt) = $self->_expand_insert_values($data);
  return (from => { -values => $v_aqt }, ($f_aqt ? (fields => $f_aqt) : ()));
}

1;
