package Games::Blockminer3D::Server::Resources;
use common::sense;
use AnyEvent;
use JSON;
use Digest::MD5 qw/md5_base64/;
use base qw/Object::Event/;

=head1 NAME

Games::Blockminer3D::Server::Resources - desc

=head1 SYNOPSIS

=head1 DESCRIPTION

=head1 METHODS

=over 4

=item my $obj = Games::Blockminer3D::Server::Resources->new (%args)

=cut

sub new {
   my $this  = shift;
   my $class = ref ($this) || $this;
   my $self  = { @_ };
   bless $self, $class;

   $self->init_object_events;

   return $self
}

sub _get_file {
   my ($file) = @_;
   open my $f, "<", $file
      or die "Couldn't open '$file': $!\n";
   do { local $/; <$f> }
}

sub load_objects {
   my ($self) = @_;
   my $objects = JSON->new->relaxed->decode (_get_file ("res/objects/types.json"));
   $self->{objects} = $objects;

   for (keys %$objects) {
      my $ob = $objects->{$_};
      $self->load_object ($_, $objects->{$_});
   }

   $self->loaded_objects;
}

sub load_texture_file {
   my ($self, $file) = @_;

   my $tex;
   unless ($self->{texture_data}->{$file}) {
      $self->{res_ids}++;

      my $data = _get_file ("res/objects/" . $file);
      my $md5  = md5_base64 ($tex->{data});
      $self->{resources}->[$self->{res_ids}] = {
         type => "texture",
         id   => $self->{res_ids},
         data => $data,
         md5  => $md5
      };

      $self->{texture_data}->{$file} = $self->{res_ids};
      warn "loaded texture $file: $self->{res_ids} $md5 " . length ($data) . "\n";
   }

   $self->{texture_data}->{$file}
}

sub load_object {
   my ($self, $name, $obj) = @_;
   if (defined $obj->{texture}) {
      $obj->{texture_id} =
         $self->load_texture ($obj->{texture});
   }
   $self->{res_ids}++;
   my $ores = $self->{resources}->[$self->{res_ids}] = {
      type => "object",
      id => $self->{res_ids},
      object_type => $obj->{type},
      texture_map_id => $obj->{texture_id},
   };
   warn "loaded object $_ => ".JSON->new->pretty->encode ($ores)."\n";
}

sub load_texture {
   my ($self, $texture_def) = @_;

   my $file = ref $texture_def ? $texture_def->[0] : $texture_def;
   my $tex_id = $self->load_texture_file ($file);

   $self->{res_ids}++;
   $self->{resources}->[$self->{res_ids}] = {
      type => "texture_mapping",
      id   => $self->{res_ids},
      data => {
         tex_id => $tex_id,
         (ref $texture_def
            ? (uv_map => [map { $texture_def->[$_] } 1..4])
            : ())
      }
   };
   $self->{res_ids}
}

sub list_resources {
   my ($self) = @_;

   my $res = [];

   for (@{$self->{resources}}) {
      push @$res, [
         $_->{id},
         $_->{type},
         $_->{md5},
         (ref $_->{data} ? $_->{data} : ())
      ];
   }

   $res
}

sub get_resources_by_id {
   my ($self, @ids) = @_;
   [
      map {
         my $res = $self->{resources}->[$_];
         [ $_, $res->{type}, $res->{md5}, \$res->{data} ]
      } @ids
   ]
}

sub loaded_objects : event_cb {
   my ($self) = @_;
   print "loadded objects:\n" . JSON->new->pretty->encode ($self->{objects}) . "\n";
}

=back

=head1 AUTHOR

Robin Redeker, C<< <elmex@ta-sa.org> >>

=head1 SEE ALSO

=head1 COPYRIGHT & LICENSE

Copyright 2009 Robin Redeker, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

1;
