package Games::Construder::Client::Resources;
use common::sense;
use File::Temp qw/tempfile/;
use SDL::Image;
use SDL::Video;
use OpenGL qw(:all);
use Games::Construder;

=head1 NAME

Games::Construder::Client::Resources - Manage textures for the Client

=head1 SYNOPSIS

=head1 DESCRIPTION

=head1 METHODS

=over 4

=item my $obj = Games::Construder::Client::Resources->new (%args)

=cut

our $VARDIR = $ENV{HOME}    ? "$ENV{HOME}/.construder"
            : $ENV{AppData} ? "$ENV{APPDATA}/construder"
            : File::Spec->tmpdir . "/construder";

our $CLCONFIG = "construder_client.json";

sub new {
   my $this  = shift;
   my $class = ref ($this) || $this;
   my $self  = { @_ };
   bless $self, $class;

   return $self
}

sub init_directories {
   my ($self) = @_;

   unless (-e $VARDIR && -d $VARDIR) {
      mkdir $VARDIR
         or die "Couldn't create var data dir '$VARDIR': $!\n";
   }

}

sub _get_file {
   my ($file) = @_;
   open my $f, "<", $file
      or die "Couldn't open '$file': $!\n";
   binmode $f, ":raw";
   do { local $/; <$f> }
}

sub load_config {
   my ($self) = @_;

   if (-e "$VARDIR/$CLCONFIG") {
      $self->{config} = JSON->new->pretty->utf8->decode (_get_file ("$VARDIR/$CLCONFIG"));

   } else {
      $self->{config} = {
         mouse_sens => 1,
      };
   }
}

sub save_config {
   my ($self) = @_;
   my $cfg = JSON->new->pretty->utf8->encode ($self->{config} ||= {});
   my $file = $VARDIR . "/" . $CLCONFIG;
   open my $c, ">", "$file~"
      or die "couldn't open '$file~' for writing: $!\n";
   binmode $c, ":raw";
   print $c $cfg or die "Couldn't write to $file~: $!\n";
   close $c or die "Couldn't close $file~: $!\n";
   rename "$file~", $file or die "Couldn't rename $file~ to $file: $!\n";
}

sub set_resources {
   my ($self, $reslist) = @_;
   for (@$reslist) {
      my ($id, $type, $md5, $data) = @$_;
      $self->{resource}->[$id] = {
         id   => $id,
         type => $type,
         data => $data,
      };
   }
}

sub post_proc {
   my ($self) = @_;

   Games::Construder::World::set_object_type (
      0, 1, 0, 0, 0, 0,
      0, 0, 0
   );
   my $objtype2texture = [];

   for (@{$self->{resource}}) {
      if ($_->{type} eq 'object') {
         my $uv;
         my $model = $_->{data}->{model};
         my $txt = [];
         warn "MODEL: " . JSON->new->pretty->encode ($_) . "\n";

         if ($_->{data}->{texture_map}) {
            my $texmap_id = $_->{data}->{texture_map};

            my $map = $self->{resource}->[$texmap_id];
            unless ($map) {
               warn "Warning: Couldn't find resource for texture map $texmap_id\n";
            }

            my $texture = $self->{resource}->[$map->{data}->{tex_id}];
            unless ($texture) {
               warn "Warning: Couldn't find resource for texture "
                    . "$map->{data}->{tex_id} in texmap $texmap_id\n";
            }

            $txt = $texture->{texture};

            $uv = [0, 0, 1, 1];
            if ($map->{data}->{uv_map}) {
               $uv = [@{$map->{data}->{uv_map}}];
               _pixel2uv ($uv, $txt->[2], $txt->[3]);
            }
         }

         my $typeid = $_->{data}->{object_type};
         $objtype2texture->[$typeid] = [
            $txt->[0], $txt->[1], $uv, $model
         ];
         Games::Construder::World::set_object_type (
            $typeid,
            ($typeid == 0 || (@$txt == 0 && defined $model ? 1 : 0)),
            $typeid != 0,
            (@$txt != 0),
            0, # not active in client
            @{$uv || [0,0,0,0]}
         );
         if ($model) {
            my ($dim, @blocks) = @$model;
            my (@constr) = map { 0 } 1..($dim ** 3);
            while (@blocks) {
               my ($nr, $type) = (shift @blocks, shift @blocks);
               $constr[$nr - 1] = $type;
            }
            Games::Construder::World::set_object_model (
               $typeid, $dim, \@constr,
            );
         }
      }
   }

   $self->{obj2txt} = $objtype2texture;
}

sub dump_resources {
   my ($self) = @_;
   for (@{$self->{resource}}) {
      if ($_->{type} eq 'object') {
         print JSON->new->pretty->encode ($_);
      } elsif ($_->{type} eq 'texture_mapping') {
         print JSON->new->pretty->allow_blessed->encode ($_);
      } else {
         print "res($_->{id}, $_->{type})[".length ($_->{data})."]\n";
      }
   }
   print JSON->new->pretty->allow_blessed->encode ($self->{obj2txt});
}

sub set_resource_data {
   my ($self, $res, $data) = @_;
   my $r = $self->{resource}->[$res->[0]]
      or return;
   if ($r->{type} eq 'texture') {
      $r->{texture} = $self->setup_texture ($data)
   }
}

sub _get_texfmt {
   my ($surface) = @_;
   my $ncol = $surface->format->BytesPerPixel;
   my $rmsk = $surface->format->Rmask;
   ($ncol == 4 ? ($rmsk == 0x000000ff ? GL_RGBA : GL_BGRA)
               : ($rmsk == 0x000000ff ? GL_RGB  : GL_BGR))
}

sub _data2surface {
   my ($data) = @_;
   my ($fh, $fname) = tempfile (SUFFIX => '.png');
   binmode $fh, ':raw';
   print $fh $data;
   close $fh;

   my $img = SDL::Image::load ($fname);
   unlink $fname;
   unless ($img) {
      die "Couldn't load texture from '$fname': " . SDL::get_error () . "\n";
   }
   $img
}

sub _pixel2uv {
   my ($uv, $w, $h) = @_;
   $uv->[2] += $uv->[0];
   $uv->[3] += $uv->[1];
   $uv->[0] /= $w;
   $uv->[2] /= $w;
   $uv->[1] /= $h;
   $uv->[3] /= $h;
   $uv->[0] += 0.002;
   $uv->[1] += 0.002;
   $uv->[2] -= 0.002;
   $uv->[3] -= 0.002;
}

#sub add_file {
#   my ($self, $name, $catalog) = @_;
#   open my $fh, "<", $name
#      or die "Couldn't open '$name': $!\n";
#   binmode $fh, ":raw";
#   my $cont = do { local $/; <$fh> };
#   $self->add ($cont, $catalog);
#}

sub setup_texture {
   my ($self, $data) = @_;

   my $surf = _data2surface ($data)
      or die "Couldn't load texture data: " . length ($data) . "\n";

   SDL::Video::lock_surface ($surf);
   my $texture_format = _get_texfmt ($surf);

   my $id = glGenTextures_p(1);
   glBindTexture (GL_TEXTURE_2D, $id);
   glTexParameterf (GL_TEXTURE_2D, GL_GENERATE_MIPMAP, GL_TRUE);
   glTexParameterf (GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR);
   glTexParameterf (GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

   glTexImage2D_s (GL_TEXTURE_2D,
      0, $surf->format->BytesPerPixel, $surf->w, $surf->h,
      0, $texture_format, GL_UNSIGNED_BYTE, ${$surf->get_pixels_ptr});

   SDL::Video::unlock_surface ($surf);

   [$id, $surf, $surf->w, $surf->h]
}

sub type_model_blocks {
   my ($self, $type) = @_;
   my $model = $self->{obj2txt}->[$type]->[3];
   @$model ? (@$model - 1) / 2 : 1
}

sub obj2texture {
   my ($self, $objid) = @_;
   @{$self->{obj2txt}->[$objid] || []}
}

sub get_opengl {
   my ($self, $nr) = @_;
 #  @{$self->{textures}->[$nr] || []}
}

sub get_sdl {
   my ($self, $nr) = @_;
   ($self->{textures}->[$nr] || [])->[2]
}

=back

=head1 AUTHOR

Robin Redeker, C<< <elmex@ta-sa.org> >>

=head1 SEE ALSO

=head1 COPYRIGHT & LICENSE

Copyright 2011 Robin Redeker, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

1;

