package Bio::DB::SeqFeature::Store::MetaDB;

use strict;
use Carp 'croak';
use IO::File;
use Bio::DB::SeqFeature::Store;

=head1 SYNOPSIS

 # override feature type, method, source and attribute fields
 # with the contents of a simple text index file

 use Bio::DB::SeqFeature::Store::MetaDB;
 use Bio::DB::SeqFeature::Store;
 my $db = Bio::DB::SeqFeature::Store->new(-adaptor=>'DBI::mysql',
                                          -dsn    =>'testdb');
 my $meta = Bio::DB::SeqFeature::Store::MetaDB->new(-store => $db,
                                                    -index => '/usr/local/testdb/meta.index');
 my @features = $meta->get_seq_stream(-seq_id => 'I',
                                      -attributes => {foo => 'bar'});
                                 
meta.index  has the following structure

 [feature_name_1]
 display_name = foobar
 type         = some_type1
 method       = my_method1
 source       = my_source1
 some_attribute    = value1
 another_attribute = value2

 [feature_name_2]
 display_name = barfoo
 type         = some_type2
 method       = my_method2
 source       = my_source2
 some_attribute    = value3
 another_attribute = value4
    
=cut

our $AUTOLOAD;

sub AUTOLOAD {
  my($pack,$func_name) = $AUTOLOAD=~/(.+)::([^:]+)$/;
  return if $func_name eq 'DESTROY';
  my $self = shift or die;
  $self->store->$func_name(@_);
}

sub isa {
    my $self = shift;
    return ref $self ? $self->store->isa(@_)
	             : Bio::DB::SeqFeature::Store->isa(@_);
}

sub new {
    my $self = shift;
    my %args = @_;
    $args{-index} or croak __PACKAGE__.'->new(): -index argument required';
    $args{-store} or croak __PACKAGE__.'->new(): -store argument required';
    return bless {
	store => $args{-store},
	index => $args{-index}};
}

sub store {shift->{store}}
sub index {shift->{index}}
sub meta {
    my $self = shift;
    return $self->{metadb} ||= $self->_parse_metadb;
}

sub get_feature {
    my $self = shift;
    my $name = shift;
    return ($self->store->get_features_by_name($name))[0];
}

sub features {
    my $self    = shift;
    my @args    = @_;
    my %options = $args[0]=~/^-/ ? @args : (-type=>$_[0]);

    my $iterator = $self->get_seq_stream(@args);
    return $iterator if $options{-iterator};
    
    my @result;
    while (my $f = $iterator->next_seq) {
	push @result,$f;
    }

    return @result;
}

sub get_seq_stream {
    my $self    = shift;
    my %options;

    if (@_ && $_[0] !~ /^-/) {
	%options = (-type => $_[0]);
    } else {
	%options = @_;
    }
    $options{-type} ||= $options{-types};

    my @ids = keys %{$self->{features}};
    @ids    = $self->_filter_ids_by_type($options{-type},           \@ids) if $options{-type};
    @ids    = $self->_filter_ids_by_attribute($options{-attributes},\@ids) if $options{-attributes};
    @ids    = $self->_filter_ids_by_name($options{-name},           \@ids) if $options{-name};

    my %search_opts  = (-type => $self->feature_type);
    $search_opts{$_} = $options{$_} foreach qw(-seq_id -start -end);

    return Bio::DB::SeqFeature::Store::MetaDB::Iterator->new($self,\@ids,\%search_opts);
}

sub get_features_by_location {
    my $self = shift;
    my ($seqid,$start,$end) = @_;
    return $self->features(-seq_id=> $seqid,
			   -start => $start,
			   -end   => $end);
}

sub get_features_by_name {
    my $self = shift;
    my $name = shift;
    return $self->features(-name  => $name);
}

sub get_feature_by_name  { shift->get_features_by_name(@_) }
sub get_features_by_alias { shift->get_features_by_name(@_) }
sub get_features_by_attribute { 
    my $self = shift;
    my $att  = shift;
    $self->features(-attributes=>$att);
}
sub _filter_ids_by_type {
    my $self = shift;
    my ($type,$ids) = @_;

    my %ids;
    my @types    = ref $type ? @$type : $type;

    my %ok_types = map {lc $_=>1} @types;
  ID:
    for my $id (@$ids) {
	my $att           = $self->{attributes}{$id};
	my $type_base     = lc ($att->{type} || $att->{method} || $att->{primary_tag} || $self->feature_type);
	{
	    no warnings;
	    my $type_extended = lc "$att->{method}:$att->{source}" if $att->{method};
	    next ID unless $ok_types{$type_base} || $ok_types{$type_extended};
	}
	$ids{$id}++;
    }

    return keys %ids;
}

sub _filter_ids_by_name {
    my $self = shift;
    my ($name,$ids) = @_;
    my $atts = $self->{attributes};
    my @result = grep {($atts->{$_}{display_name} || $atts->{$_}{name}) eq $name} @$ids;
    return @result;
}

sub _filter_ids_by_attribute {
    my $self = shift;
    my ($attributes,$ids) = @_;

    my @result;
    my %ids = map {$_=>1} @$ids;
    for my $att_name (keys %$attributes) {
	my @search_terms = ref($attributes->{$att_name}) && ref($attributes->{$att_name}) eq 'ARRAY'
	                   ? @{$attributes->{$att_name}} : $attributes->{$att_name};
	for my $id (keys %ids) {
	    my $ok;
	    
	    for my $v (@search_terms) {
		my $att = $self->{attributes}{$id} or next;
		my $val = $att->{lc $att_name}     or next;
		if (my $regexp = $self->glob_match($v)) {
		    $ok++ if $val =~ /$regexp/i;
		} else {
		    $ok++ if lc $val eq lc $v;
		}
	    }
	    delete $ids{$id} unless $ok;
	}
    }
    return keys %ids;
}

sub glob_match {
  my $self = shift;
  my $term = shift;
  return unless $term =~ /(?:^|[^\\])[*?]/;
  $term =~ s/(^|[^\\])([+\[\]^{}\$|\(\).])/$1\\$2/g;
  $term =~ s/(^|[^\\])\*/$1.*/g;
  $term =~ s/(^|[^\\])\?/$1./g;
  return $term;
}

sub _parse_metadb {
    my $self = shift;
    my $file = $self->index;

    my $f;
    if ($file =~ /^(ftp|http):/i) {
	eval "require LWP::UserAgent; 1"
	    or die "LWP::UserAgent module is required for remote metadata indexes"
	    unless LWP::UserAgent->can('new');
	my $ua = LWP::UserAgent->new;
	my $r  = $ua->get($file);
	die "Couldn't read $file: ",$r->status_line unless $r->is_success;
	eval "require IO::String; 1" 
	    or die "IO::String module is required for remote directories"
	    unless IO::String->can('new');
	$f = IO::String->new($r->decoded_content);
    }
    else {
	$f = IO::File->new($file) or die "$file: $!";
    }
    my ($current_feature,%features);

    while (<$f>) {
	chomp;
	s/\s+$//;   # strip whitespace at ends of lines
	# strip right-column comments unless they look like colors or html fragments
	s/\s*\#.*$// unless /\#[0-9a-f]{6,8}\s*$/i || /\w+\#\w+/ || /\w+\"*\s*\#\d+$/;   
	if (/^\[([^\]]+)\]/) {  # beginning of a configuration section
	    my $current_feature = $1;
	}

	elsif ($current_feature && /^([\w: -]+?)\s*=\s*(.*)/) {  # key value pair
	    my $tag = lc $1;
	    my $value = defined $2 ? $2 : '';
	    $features{$current_feature}{$tag}=$value;
	}
    }

    for my $f (keys %features) {
	my $attributes = $features{$f};
	$self->set_feature_attributes($f,$attributes);
    }

}

sub set_feature_attributes {
    my $self = shift;
    my ($feature,$attributes) = @_;
    if (my $old = $self->{attributes}{$feature}) {
	%$attributes = (%$old,%$attributes);  # merge
    }
    $self->{features}{$feature}    ||= undef;
    $self->{attributes}{$feature}    = $attributes;
}

package Bio::DB::SeqFeature::Store::MetaDB::Iterator;

sub new {
    my $class = shift;
    my ($set,$ids,$search_opts) = @_;
    return bless {set         => $set,
		  ids         => $ids,
		  search_opts => $search_opts,
    },ref $class || $class;
}

sub next_seq {
    my $self = shift;
    my $set  = $self->{set};
    my $ids  = $self->{ids};
    my $opts = $self->{search_opts};

    while (1) {
	if (my $i = $self->{current_iterator}) {
	    if (my $next = $i->next_seq) {
		my $id   = $self->{current_id};
		my $att  = $set->{attributes}{$id};
		if ($att) {
		    $next->set_attributes($att);
		    my ($method,$source) = split(':',$att->{type}||'');
		    $next->primary_tag($method || $att->{primary_tag}) if $method || $att->{primary_tag};
		    $next->source_tag ($source || $att->{source}     ) if $source || $att->{source};
		}
		return $next;
	    }
	}
	$self->{current_id}       = shift @$ids or return;  # leave when we run out of ids
	my $bw                    = $set->get_feature($self->{current_id}) or next;
	$self->{current_iterator} = $bw->get_seq_stream(%$opts,-type=>$set->feature_type);
    }
}

1;
