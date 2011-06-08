package Games::Construder::Server::Player;
use Devel::FindRef;
use common::sense;
use AnyEvent;
use Games::Construder::Server::World;
use Games::Construder::Server::UI;
use Games::Construder::Server::Objects;
use Games::Construder::Vector;
use base qw/Object::Event/;
use Scalar::Util qw/weaken/;
use Compress::LZF;

=head1 NAME

Games::Construder::Server::Player - desc

=head1 SYNOPSIS

=head1 DESCRIPTION

=head1 METHODS

=over 4

=item my $obj = Games::Construder::Server::Player->new (%args)

=cut

my $PL_VIS_RAD = 3;
my $PL_MAX_INV = 28;

sub new {
   my $this  = shift;
   my $class = ref ($this) || $this;
   my $self  = { @_ };
   bless $self, $class;

   $self->init_object_events;

   return $self
}

sub _check_file {
   my ($self) = @_;
   my $pld = $Games::Construder::Server::Resources::PLAYERDIR;
   my $file = "$pld/$self->{name}.json";
   return unless -e "$file";

   if (open my $plf, "<", $file) {
      binmode $plf, ":raw";
      my $cont = do { local $/; <$plf> };
      my $data = eval { JSON->new->relaxed->utf8->decode ($cont) };
      if ($@) {
         warn "Couldn't parse player data from file '$file': $!\n";
         return;
      }

      return $data

   } else {
      warn "Couldn't open player file $file: $!\n";
      return;
   }
}

sub _initialize_player {
   my ($self) = @_;
   my $inv = $Games::Construder::Server::RES->get_initial_inventory;
   my $data = {
      name      => $self->{name},
      happyness => 100,
      bio       => 100,
      score     => 0,
      pos       => [0, 0, 0],
      inv       => $inv,
      slots => {
         selection => [keys %$inv],
         selected  => 0
      },
   };

   $data
}

sub load {
   my ($self) = @_;

   my $data = $self->_check_file;
   unless (defined $data) {
      $data = $self->_initialize_player;
   }

   $self->{data} = $data;
}

sub save {
   my ($self) = @_;
   my $cont = JSON->new->pretty->utf8->encode ($self->{data});
   my $pld = $Games::Construder::Server::Resources::PLAYERDIR;
   my $file = "$pld/$self->{name}.json";

   if (open my $plf, ">", "$file~") {
      binmode $plf, ":raw";
      print $plf $cont;
      close $plf;

      if (-s "$file~" != length ($cont)) {
         warn "Couldn't write out player file completely to '$file~': $!\n";
         return;
      }

      unless (rename "$file~", "$file") {
         warn "Couldn't rename $file~ to $file: $!\n";
         return;
      }

      warn "saved player $self->{name} to $file.\n";

   } else {
      warn "Couldn't open player file $file~ for writing: $!\n";
      return;
   }
}

sub init {
   my ($self) = @_;
   $self->load;
   $self->save;
   my $wself = $self;
   weaken $wself;
   my $tick_time = time;
   $self->{tick_timer} = AE::timer 0.25, 0.25, sub {
      my $cur = time;
      $wself->player_tick ($cur - $tick_time);
      $tick_time = $cur;
   };

   $self->new_ui (bio_warning   => "Games::Construder::Server::UI::BioWarning");
   $self->new_ui (msgbox        => "Games::Construder::Server::UI::MsgBox");
   $self->new_ui (score         => "Games::Construder::Server::UI::Score");
   $self->new_ui (slots         => "Games::Construder::Server::UI::Slots");
   $self->new_ui (status        => "Games::Construder::Server::UI::Status");
   $self->new_ui (material_view => "Games::Construder::Server::UI::MaterialView");
   $self->new_ui (inventory     => "Games::Construder::Server::UI::Inventory");
   $self->new_ui (cheat         => "Games::Construder::Server::UI::Cheat");
   $self->new_ui (sector_finder => "Games::Construder::Server::UI::SectorFinder");
   $self->new_ui (navigator     => "Games::Construder::Server::UI::Navigator");
   $self->new_ui (assignment      => "Games::Construder::Server::UI::Assignment");
   $self->new_ui (assignment_time => "Games::Construder::Server::UI::AssignmentTime");

   $self->update_score;
   $self->{uis}->{slots}->show;
   $self->send_visible_chunks;
   $self->teleport ();
   $self->check_assignment;
}

sub push_tick_change {
   my ($self, $key, $amt) = @_;
   push @{$self->{tick_changes}}, [$key, $amt];
}

sub player_tick {
   my ($self, $dt) = @_;

   my $player_values = $Games::Construder::Server::RES->player_values ();

   while (@{$self->{tick_changes}}) {
      my ($k, $a) = @{shift @{$self->{tick_changes}}};

      if ($k eq 'happyness' || $k eq 'bio') {
         $self->{data}->{$k} += $a;

         if ($self->{data}->{$k} > 100) {
            $self->{data}->{$k} = 100;
         }

      } elsif ($k eq 'score') {
         my $happy = $Games::Construder::Server::RES->score2happyness ($a);
         $self->{data}->{happyness} += int ($happy + 0.5);

         if ($self->{data}->{happyness} < 90) {
            $a = 0;
         } elsif ($self->{data}->{happyness} > 100) {
            $self->{data}->{happyness} = 100;
         }

         if ($a) {
            $self->update_score ($a);
            $self->{data}->{score} += $a;
            $self->{data}->{score} = int $self->{data}->{score};
         }
      }
   }

   my $bio_rate;

   $self->{data}->{happyness} -= $dt * $player_values->{unhappy_rate};
   if ($self->{data}->{happyness} < 0) {
      $self->{data}->{happyness} = 0;
      $bio_rate = $player_values->{bio_unhappy};

   } elsif ($self->{data}->{happyness} > 0) {
      $bio_rate = $player_values->{bio_happy};
   }

   $self->{data}->{bio} -= $dt * $bio_rate;
   if ($self->{data}->{bio} <= 0) {
      $self->{data}->{bio} = 0;

      if (!$self->try_eat_something) { # danger: this maybe recurses into player_tick :)
         $self->starvation (1);
      }
   } else {
      $self->starvation (0);
   }

   my $hunger = 100 - $self->{data}->{bio};
   $self->try_eat_something ($hunger);
}

sub starvation {
   my ($self, $starves) = @_;

   my $bio_ui = $self->{uis}->{bio_warning};

   if ($starves) {
      unless ($self->{death_timer}) {
         my $cnt = 30;
         $self->{death_timer} = AE::timer 0, 1, sub {
            if ($cnt-- <= 0) {
               $self->kill_player;
               delete $self->{death_timer};

               $bio_ui->hide;
            } else {
               $bio_ui->show ($cnt);
            }
         };
      }

   } else {
      if (delete $self->{death_timer}) {
         $bio_ui->hide;
      }
   }
}

sub has_inventory_space {
   my ($self, $type, $cnt) = @_;
   $cnt ||= 1;
   my ($spc, $max) = $self->inventory_space_for ($type);
   $spc >= $cnt
}

sub increase_inventory {
   my ($self, $type, $cnt) = @_;

   $cnt ||= 1;

   my ($spc, $max) = $self->inventory_space_for ($type);
   if ($spc > 0) {
      $cnt = $spc if $spc < $cnt;
      $self->{data}->{inv}->{$type} += $cnt;

      if ($self->{uis}->{inventory}->{shown}) {
         $self->{uis}->{inventory}->show; # update if neccesary
      }

      $self->{uis}->{slots}->show;

      return $cnt;
   }
   0
}

sub decrease_inventory {
   my ($self, $type, $cnt) = @_;

   $cnt ||= 1;

   my $old_val = 0;

   if ($type eq 'all') {
      $self->{data}->{inv} = {};

   } else {
      $old_val = $self->{data}->{inv}->{$type};
      $self->{data}->{inv}->{$type} -= $cnt;
      if ($self->{data}->{inv}->{$type} <= 0) {
         delete $self->{data}->{inv}->{$type};
      }
   }

   if ($self->{uis}->{inventory}->{shown}) {
      $self->{uis}->{inventory}->show; # update if neccesary
   }

   $self->{uis}->{slots}->show;

   $old_val > 0
}

sub try_eat_something {
   my ($self, $amount) = @_;

   my (@max_e) = sort {
      $b->[1] <=> $a->[1]
   } grep { $_->[1] } map {
      my $obj = $Games::Construder::Server::RES->get_object_by_type ($_);
      [$_, $obj->{bio_energy}]
   } keys %{$self->{data}->{inv}};

   return 0 unless @max_e;

   if ($amount) {
      my $item = $max_e[0];
      if ($item->[1] <= $amount) {
         if ($self->decrease_inventory ($item->[0])) {
            $self->refill_bio ($item->[1]);
            return 1;
         }
      }

   } else {
      while (@max_e) { # eat anything!
         my $res = shift @max_e;
         if ($self->decrease_inventory ($res->[0])) {
            $self->refill_bio ($res->[1]);
            return 1;
         }
      }
   }

   return 0;
}

sub refill_bio {
   my ($self, $amount) = @_;

   $self->{data}->{bio} += $amount;
   $self->{data}->{bio} = 100
      if $self->{data}->{bio} > 100;

   if ($self->{data}->{bio} > 0) {
      $self->starvation (0); # make sure we don't starve anymore
   }
}

sub kill_player {
   my ($self) = @_;
   $self->teleport ([0, 0, 0]);
   $self->decrease_inventory ('all');
   $self->{data}->{happyness} = 100;
   $self->{data}->{bio}       = 100;
   $self->{data}->{score}    -=
      int ($self->{data}->{score} * (20 / 100)); # 20% score loss

}

sub logout {
   my ($self) = @_;
   $self->save;
   delete $self->{uis};
   delete $self->{upd_score_hl_tmout};
   delete $self->{death_timer};
   warn "player $self->{name} logged out\n";
   print Devel::FindRef::track $self;
}

my $world_c = 0;

sub _visible_chunks {
   my ($from, $chnk) = @_;

   my $plchnk = world_pos2chnkpos ($from);
   $chnk ||= $plchnk;

   my @c;
   for my $dx (-$PL_VIS_RAD..$PL_VIS_RAD) {
      for my $dy (-$PL_VIS_RAD..$PL_VIS_RAD) {
         for my $dz (-$PL_VIS_RAD..$PL_VIS_RAD) {
            my $cur = [$chnk->[0] + $dx, $chnk->[1] + $dy, $chnk->[2] + $dz];
            next if vlength (vsub ($cur, $plchnk)) >= $PL_VIS_RAD;
            push @c, $cur;
         }
      }
   }

   @c
}

sub update_pos {
   my ($self, $pos, $lv) = @_;

   my $opos = $self->{data}->{pos};
   $self->{data}->{pos} = $pos;
   my $olv = $self->{data}->{look_vec} || [0,0,0];
   $self->{data}->{look_vec} = vnorm ($lv);

   my $oblk = vfloor ($opos);
   my $nblk = vfloor ($pos);

   my $new_pos = vlength (vsub ($oblk, $nblk)) > 0;
   my $new_lv  = vlength (vsub ($olv, $lv)) > 0.05;
   my $dnew_lv = vlength (vsub ($olv, $lv));

   if ($new_pos || $new_lv) {
      if ($self->{uis}->{navigator}->{shown}) {
         $self->{uis}->{navigator}->show;
      }
   }

   return unless $new_pos;

   # just trigger this, if new chunks are generated or loaded they
   # will be automatically sent if visible by chunk_updated.
   world_load_at ($pos); # fixme: still blocks for now :)

   # send whats available for now
   my $last_vis = $self->{last_vis} || {};
   my $next_vis = {};
   my @chunks   = _visible_chunks ($pos);
   my @new_chunks;
   for (@chunks) {
      my $id = world_pos2id ($_);
      unless ($last_vis->{$id}) {
         push @new_chunks, $_;
      }
      $next_vis->{$id} = 1;
   }
   $self->{last_vis} = $next_vis;

   if (@new_chunks) {
      $self->send_client ({ cmd => "chunk_upd_start" });
      $self->send_chunk ($_) for @new_chunks;
      $self->send_client ({ cmd => "chunk_upd_done" });
   }
}

sub get_pos_normalized {
   my ($self) = @_;
   vfloor ($self->{data}->{pos})
}

sub get_pos_chnk {
   my ($self) = @_;
   world_pos2chnkpos ($self->{data}->{pos})
}

sub get_pos_sector {
   my ($self) = @_;
   world_chnkpos2secpos (world_pos2chnkpos ($self->{data}->{pos}))
}

sub chunk_updated {
   my ($self, $chnk) = @_;

   my $plchnk = world_pos2chnkpos ($self->{data}->{pos});
   my $divvec = vsub ($chnk, $plchnk);
   return if vlength ($divvec) >= $PL_VIS_RAD;

   $self->send_chunk ($chnk);
}

sub send_visible_chunks {
   my ($self) = @_;

   $self->send_client ({ cmd => "chunk_upd_start" });

   my @chnks = _visible_chunks ($self->{data}->{pos});
   $self->send_chunk ($_) for @chnks;

   warn "done sending " . scalar (@chnks) . " visible chunks.\n";
   $self->send_client ({ cmd => "chunk_upd_done" });
}

sub send_chunk {
   my ($self, $chnk) = @_;

   # only send chunk when allcoated, in all other cases the chunk will
   # be sent by the chunk_changed-callback by the server (when it checks
   # whether any player might be interested in that chunk).
   my $data = Games::Construder::World::get_chunk_data (@$chnk);
   return unless defined $data;
   $self->send_client ({ cmd => "chunk", pos => $chnk }, compress ($data));
}

sub msg {
   my ($self, $error, $msg) = @_;
   $self->{uis}->{msgbox}->show ($error, $msg);
}

sub update_score {
   my ($self, $hl) = @_;
   $self->{uis}->{score}->show ($hl);
}

sub query {
   my ($self, $pos) = @_;
   return unless @$pos;

   world_mutate_at ($pos, sub {
      my ($data) = @_;
      if ($data->[0]) {
         $self->{uis}->{material_view}->show ($data->[0]);
      }
      return 0;
   });

}

sub interact {
   my ($self, $pos) = @_;

   world_mutate_at ($pos, sub {
      my ($data) = @_;
      print "interact position [@$pos]: @$data\n";
      Games::Construder::Server::Objects::interact ($self, $data->[0], $pos);
      return 0;
   });
}

sub highlight {
   my ($self, $pos, $time, $color) = @_;
   $self->send_client ({
      cmd   => "highlight",
      pos   => $pos,
      color => $color,
      fade  => -$time
   });
}

sub debug_at {
   my ($self, $pos) = @_;
   $self->send_client ({
      cmd => "model_highlight",
      pos => $pos,
      model => [
         map {
            my $x = $_;
            map {
               my $y = $_;
               map { [$x, $y, $_] } 0..10
            } 0..10
         } 0..10
      ],
      color => [1, 0, 1, 0.2],
      id => "debug"
   });
   world_mutate_at ($pos, sub {
      my ($data) = @_;
      print "position [@$pos]: @$data\n";
      if ($data->[0] == 1) {
         $data->[0] = 0;
         return 1;
      }
      return 0;
   });
}

sub do_materialize {
   my ($self, $pos, $type, $time, $energy, $score) = @_;

   my $id = world_pos2id ($pos);

   $self->highlight ($pos, $time, [0, 1, 0]);

   $self->push_tick_change (bio => -$energy);

   $self->{materializings}->{$id} = 1;
   my $tmr;
   $tmr = AE::timer $time, 0, sub {
      world_mutate_at ($pos, sub {
         my ($data) = @_;
         undef $tmr;

         $data->[0] = $type;
        #d# $data->[3] = 0x2;
         delete $self->{materializings}->{$id};
         $self->push_tick_change (score => $score);
         return 1;
      });
   };
}

sub start_materialize {
   my ($self, $pos) = @_;

   my $id = world_pos2id ($pos);
   if ($self->{materializings}->{$id}) {
      return;
   }

   my $type = $self->{data}->{slots}->{selection}->[$self->{data}->{slots}->{selected}];

   world_mutate_at ($pos, sub {
      my ($data) = @_;

      return 0 unless $data->[0] == 0;

      return 0 unless $self->decrease_inventory ($type);

      my $obj = $Games::Construder::Server::RES->get_object_by_type ($type);
      my ($time, $energy, $score) =
         $Games::Construder::Server::RES->get_type_materialize_values ($type);
      unless ($self->{data}->{bio} >= $energy) {
         $self->msg (1, "You don't have enough energy to materialize the $obj->{name}!");
         return;
      }

      $data->[0] = 1;
      $self->do_materialize ($pos, $type, $time, $energy, $score);
      return 1;
   }, no_light => 1);
}

sub inventory_space_for {
   my ($self, $type) = @_;
   my $spc = $Games::Construder::Server::RES->get_type_inventory_space ($type);
   my $cnt;
   if (exists $self->{data}->{inv}->{$type}) {
      $cnt = $self->{data}->{inv}->{$type};
   } else {
      if (scalar (grep { $_ ne '' && $_ != 0 } keys %{$self->{data}->{inv}}) >= $PL_MAX_INV) {
         $cnt = $spc;
      }
   }

   my $dlta = $spc - $cnt;

   ($dlta < 0 ? 0 : $dlta, $spc)
}

sub do_dematerialize {
   my ($self, $pos, $type, $time, $energy) = @_;

   my $id = world_pos2id ($pos);
   $self->highlight ($pos, $time, [1, 0, 0]);

   $self->push_tick_change (bio => -$energy);

   $self->{dematerializings}->{$id} = 1;
   my $tmr;
   $tmr = AE::timer $time, 0, sub {
      undef $tmr;

      world_mutate_at ($pos, sub {
         my ($data) = @_;
         warn "INCREATE $type\n";
         $data->[0] = 0;
         $data->[3] &= 0xF0; # clear color :)
         delete $self->{dematerializings}->{$id};
         $self->increase_inventory ($type);
         return 1;
      });
   };
}

sub start_dematerialize {
   my ($self, $pos) = @_;

   my $id = world_pos2id ($pos);
   if ($self->{dematerializings}->{$id}) {
      return;
   }

   world_mutate_at ($pos, sub {
      my ($data) = @_;
      my $type = $data->[0];
      my $obj = $Games::Construder::Server::RES->get_object_by_type ($type);
      if ($obj->{untransformable}) {
         return;
      }
      warn "DEMAT $type\n";

      unless ($self->has_inventory_space ($type)) {
         $self->msg (1, "Inventory full, no space for $obj->{name} available!");
         return;
      }

      my ($time, $energy) =
         $Games::Construder::Server::RES->get_type_dematerialize_values ($type);
      unless ($obj->{bio_energy} || $self->{data}->{bio} >= $energy) {
         $self->msg (1, "You don't have enough energy to dematerialize the $obj->{name}!");
         return;
      }

      $data->[0] = 1; # materialization!
      $self->do_dematerialize ($pos, $type, $time, $energy);

      return 1;
   }, no_light => 1);
}

sub create_assignment {
   my ($self) = @_;

   my $x = (rand () * 2) - 1;
   my $y = (rand () * 2) - 1;
   my $z = (rand () * 2) - 1;

   my $score = $self->{data}->{score};

   $score /= 1000;

   my $dist = ($score + rand ($score)) + 1;

   my $vec = vsmul (vnorm ([$x, $y, $z]), $dist);
   my $sec = vfloor (vadd ($vec, $self->get_pos_sector));

   warn "assignment at @$vec => @$sec\n";

   my $cal = $self->{data}->{assignment} = {
      sec => $sec,
      score => $score * 5000,
      time => int (60 * $dist),
   };

   $self->{uis}->{assignment}->show;

   $self->check_assignment;

   # generate random sector position
   #      parameter: distance
   #
   # determine form of construct: wire-frame cube, cube, platform
   #
   # determine size (count of source) of construct
   #
   # determine how many different materials need to be used:
   #   generate source materials:
   #      depends on score of player,
   #      metrics need to come from the world_gen.json for this
   #      (metrics ala which score means which source materials)
   #      level of source materials is computed from
   #      types.json
   #        - calculation calculates distance from root-materials
   #        - root-materials get some value that indicates whether
   #          they are rated as "rare" or not. => this can probably be done
   #          easier manually than by looking at their actual occurance in the sectors.
   #
   # determine how long the player has
   #   - use some world_gen base value as measurement how long a player has
   #     to cover the distance 1
   #   - on high levels this can be shrunken, player should use teleporters!
   #
   # determine punishment for player: how much score he loses
   #
   # => make assignment description, display assignment, start counter
   #    store assignment in player data
   #    time counter should be on player, and counted down in 10 sec intervals
   #    on player load assignment timers have to be restarted
}

sub check_assignment {
   my ($self) = @_;
   my $assign = $self->{data}->{assignment};
   unless ($assign) {
      $self->{uis}->{assignment_time}->hide;
      return;
   }

   $self->{uis}->{assignment_time}->show;
   my $wself = $self;
   weaken $wself;
   $self->{assign_timer} = AE::timer 1, 1, sub {
      $wself->{data}->{assignment}->{time} -= 1;
      $wself->{uis}->{assignment_time}->show;
      if ($wself->{data}->{assignment}->{time} <= 0) {
         $wself->cancel_assignment;
      }
   };
}

sub cancel_assignment {
   my ($self) = @_;
   $self->{data}->{assignment} = undef;
   $self->check_assignment;
}

sub send_client : event_cb {
   my ($self, $hdr, $body) = @_;
}

sub teleport {
   my ($self, $pos) = @_;

   $pos ||= $self->{data}->{pos};
   world_load_at ($pos, sub {
      my $new_pos = world_find_free_spot ($pos, 1);
      unless ($new_pos) {
         $new_pos = world_find_free_spot ($pos, 0); # without floor on second try
      }
      $new_pos = vaddd ($new_pos, 0.5, 0.5, 0.5);
      $self->send_client ({ cmd => "place_player", pos => $new_pos });
   });
}

sub new_ui {
   my ($self, $id, $class, %arg) = @_;
   my $o = $class->new (ui_name => $id, pl => $self, %arg);
   $self->{uis}->{$id} = $o;
}

sub delete_ui {
   my ($self, $id) = @_;
   delete $self->{uis}->{$id};
}

sub display_ui {
   my ($self, $id, $dest) = @_;

   my $o = $self->{uis}->{$id};

   unless ($dest) {
      $self->send_client ({ cmd => deactivate_ui => ui => $id });
      delete $o->{shown};
      return;
   }

   $self->send_client ({ cmd => activate_ui => ui => $id, desc => $dest });
   $o->{shown} = 1;
}

sub ui_res : event_cb {
   my ($self, $ui, $cmd, $arg, $pos) = @_;
   warn "ui response $ui: $cmd ($arg) (@$pos)\n";

   if (my $o = $self->{uis}->{$ui}) {
      $o->react ($cmd, $arg, $pos);

      delete $o->{shown}
         if $cmd eq 'cancel';
   }
}

sub DESTROY {
   my ($self) = @_;
   warn "player $self->{name} [$self] destroyed!\n";
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
