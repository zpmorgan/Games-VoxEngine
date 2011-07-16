# Games::VoxEngine - A 3D Game written in Perl with an infinite and modifiable world.
# Copyright (C) 2011  Robin Redeker
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
package Games::VoxEngine::Server::Objects;
use common::sense;
use Games::VoxEngine::Server::PCB;
use Games::VoxEngine::Server::World;
use Games::VoxEngine::Vector;
use Games::VoxEngine;
use Scalar::Util qw/weaken/;

=head1 NAME

Games::VoxEngine::Server::Objects - Implementation of Object Type specific behaviour

=over 4

=cut

our %TYPES = (
   31 => \&ia_pattern_storage,
   34 => \&ia_message_beacon,
   36 => \&ia_construction_pad,
   45 => \&ia_vaporizer,
   46 => \&ia_vaporizer,
   47 => \&ia_vaporizer,
   48 => \&ia_vaporizer,
   62 => \&ia_teleporter,
   51 => \&ia_auto,
);

our %TYPES_INSTANCIATE = (
   31 => \&in_pattern_storage,
   34 => \&in_message_beacon,
   45 => \&in_vaporizer,
   46 => \&in_vaporizer,
   47 => \&in_vaporizer,
   48 => \&in_vaporizer,
   50 => \&in_drone,
   51 => \&in_auto,
   62 => \&in_teleporter,
   70 => \&in_mat_upgrade,
   500 => \&in_trophy,
   501 => \&in_trophy,
   502 => \&in_trophy,
   503 => \&in_trophy,
   504 => \&in_trophy,
   505 => \&in_trophy,
);

our %TYPES_TIMESENSITIVE = (
   31 => \&tmr_pattern_storage,
   45 => \&tmr_vaporizer,
   46 => \&tmr_vaporizer,
   47 => \&tmr_vaporizer,
   48 => \&tmr_vaporizer,
   50 => \&tmr_drone,
   51 => \&tmr_auto,
);

our %TYPES_PERSISTENT = (
   # for pattern storage for instance
   # or a build agent
);

sub interact {
   my ($player, $pos, $type, $entity) = @_;
   my $cb = $TYPES{$type}
      or return;
   $cb->($player, $pos, $type, $entity);
}

sub destroy {
   my ($ent) = @_;
   # nop for now
}

sub instance {
   my ($type, @arg) = @_;

   my $cb = $TYPES_INSTANCIATE{$type}
      or return;
   my $i = $cb->($type, @arg);
   $i->{type} = $type;
   $i->{tmp} ||= {};
   $i
}

sub tick {
   my ($pos, $entity, $type, $dt) = @_;
   my $cb = $TYPES_TIMESENSITIVE{$type}
      or return;
   $cb->($pos, $entity, $type, $dt)
}

sub in_trophy {
   {
      label => "ACME Inc.",
   }
}

sub in_mat_upgrade {
   { }
}

sub in_vaporizer {
   my ($type) = @_;
   my $time = 1;
   if ($type == 46) {
      $time = 2;
   } elsif ($type == 47) {
      $time = 4;
   } elsif ($type == 48) {
      $time = 8;
   }

   {
      time => $time,
   }
}

sub tmr_vaporizer {
   my ($pos, $entity, $type, $dt) = @_;
   warn "vapo tick: $dt ($type, $entity)\n";

   $entity->{tmp}->{accumtime} += $dt;
   if ($entity->{tmp}->{accumtime} >= $entity->{time}) {
      my $rad = $entity->{tmp}->{rad};
      my $pos = $entity->{tmp}->{pos};

      my @poses;
      for my $x (-$rad..$rad) {
         for my $y (-$rad..$rad) {
            for my $z (-$rad..$rad) {
               push @poses, my $p = vaddd ($pos, $x, $y, $z);
            }
         }
      }

      world_mutate_at (\@poses, sub {
         my ($d) = @_;
         if ($d->[0] != 0) {
            $d->[0] = 0;
            $d->[3] &= 0xF0; # clear color :)
            return 1
         }
         0
      });
   }
}

sub ia_vaporizer {
   my ($PL, $POS, $type, $entity) = @_;


   my $rad = 1; # type == 45
   if ($type ==  46) {
      $rad = 2;
   } elsif ($type ==  47) {
      $rad = rand (100) > 20 ? 5 : 0;
   } elsif ($type ==  48) {
      $rad = rand (100) > 60 ? 10 : int (rand () * 9) + 1;
   }

   my $time = $entity->{time};
   my (@pl) =
      $Games::VoxEngine::Server::World::SRV->players_near_pos ($POS);
   for my $x (-$rad..$rad) {
      $_->[0]->highlight (vaddd ($POS, $x, 0, 0), $time, [1, 1, 0]) for @pl;
   }
   for my $y (-$rad..$rad) {
      $_->[0]->highlight (vaddd ($POS, 0, $y, 0), $time, [1, 1, 0]) for @pl;
   }
   for my $z (-$rad..$rad) {
      $_->[0]->highlight (vaddd ($POS, 0, 0, $z), $time, [1, 1, 0]) for @pl;
   }

   $entity->{time_active} = 1;
   $entity->{tmp}->{rad} = $rad;
   $entity->{tmp}->{pos} = [@$POS];

}

sub ia_construction_pad {
   my ($PL, $POS) = @_;

   my $a = Games::VoxEngine::World::get_pattern (@$POS, 0);
   if ($a) {
      my $obj = $Games::VoxEngine::Server::RES->get_object_by_pattern ($a);
      if ($obj) {
         my ($score, $time) =
            $Games::VoxEngine::Server::RES->get_type_construct_values ($obj->{type});

         if ($PL->{inv}->has_space_for ($obj->{type})) {
            my $a = Games::VoxEngine::World::get_pattern (@$POS, 1);

            my @poses;
            while (@$a) {
               my $pos = [shift @$a, shift @$a, shift @$a];
               push @poses, $pos;
               $PL->highlight ($pos, $time, [0, 0, 1]);
            }

            world_mutate_at (\@poses, sub {
               my ($data) = @_;
               $data->[0] = 1;
               $data->[3] &= 0xF0; # clear color :)
               my $ent = $data->[5]; # kill entity
               $data->[5] = undef;
               if ($ent) {
                  Games::VoxEngine::Server::Objects::destroy ($ent);
               }
               1
            }, no_light => 1);

            my $tmr;
            $tmr = AE::timer $time, 0, sub {
               world_mutate_at (\@poses, sub {
                  my ($data) = @_;
                  $data->[0] = 0;
                  1
               });

               my $gen_cnt = $obj->{model_cnt} || 1; # || 1 shouldn't happen... but u never know

               my $cnt =
                  $obj->{permanent}
                     ? instance ($obj->{type})
                     : $gen_cnt;

               my $add_cnt =
                  $PL->{inv}->add ($obj->{type}, $cnt);
               if ($add_cnt > 0) {
                  $PL->push_tick_change (score => $score);
               }

               $PL->msg (0,
                  "Added $add_cnt of $gen_cnt $obj->{name} to your inventory."
                  . ($gen_cnt > $add_cnt ? " The rest was discarded." : ""));

               undef $tmr;
            };

         } else {
            $PL->msg (1, "The created $obj->{name} would not fit into your inventory!");
         }
      } else {
         $PL->msg (1, "Pattern not recognized!");
      }
   } else {
      $PL->msg (1, "No properly built construction floor found!");
   }
}

sub in_pattern_storage {
   {
      inv => {
         ent => {},
         mat => {},
      },
   }
}

sub tmr_pattern_storage {
   my ($pos, $entity, $type, $dt) = @_;
}

sub ia_pattern_storage {
   my ($pl, $pos, $type, $entity) = @_;
   $pl->{uis}->{pattern_storage}->show ($pos, $entity);
}

sub in_message_beacon {
   {
      msg => "<unset message>"
   }
}

sub ia_message_beacon {
   my ($pl, $pos, $type, $entity) = @_;
   $pl->{uis}->{msg_beacon}->show ($pos, $entity);
}

sub in_teleporter {
   {
      msg => "<no destination>",
   }
}

sub ia_teleporter {
   my ($pl, $pos, $type, $entity) = @_;
   $pl->{uis}->{teleporter}->show ($pos);
}

sub in_drone {
   my ($type, $lifeticks, $teledist) = @_;
   {
      time_active   => 1,
      orig_lifetime => $lifeticks,
      lifetime      => $lifeticks,
      teleport_dist => $teledist,
   }
}

sub drone_kill {
   my ($pos, $entity) = @_;
   world_mutate_at ($pos, sub {
      my ($data) = @_;
      #d#warn "CHECK AT @$pos: $data->[0]\n";
      if ($data->[0] == 50) {
         warn "DRONE $entity DIED at @$pos\n";
         $data->[0] = 0;
         return 1;
      } else {
         warn "ERROR: DRONE $entity should have been at @$pos and dead. But couldn't find it!\n";
      }
      return 0;
   });
}

sub drone_visible_players {
   my ($pos, $entity) = @_;

   sort {
      $a->[1] <=> $b->[1]
   } grep {
      not $_->[0]->{data}->{signal_jammed}
   } $Games::VoxEngine::Server::World::SRV->players_near_pos ($pos);
}

sub drone_check_player_hit {
   my ($pos, $entity, $pl) = @_;

   unless ($pl) {
      my (@pl) = drone_visible_players ($pos, $entity)
         or return;
      $pl = $pl[0]->[0];
   }

   if (vlength (vsub ($pl->{data}->{pos}, $pos)) <= 1.1) {
      my $dist = $entity->{teleport_dist} * 60;
      my ($new_pl_pos, $dist, $secdist) =
         world_find_random_teleport_destination_at_dist ($pl->{data}->{pos}, $dist);
      $dist = int $dist;
      $pl->teleport ($new_pl_pos);
      $pl->push_tick_change (happyness => -100);
      $pl->msg (1, "A Drone displaced you by $dist.");
      drone_kill ($pos, $entity);
   }
}

sub tmr_drone {
   my ($pos, $entity, $type, $dt) = @_;

   #d#warn "DRONE $entity LIFE $entity->{lifetime} from $entity->{orig_lifetime} at @$pos\n";
   $entity->{lifetime}--;
   if ($entity->{lifetime} <= 0) {
      drone_kill ($pos, $entity);
      return;
   }

   if ($entity->{in_transition}) {
      $entity->{transition_time} -= $dt;

      if ($entity->{transition_time} <= 0) {
         delete $entity->{in_transition};

         my $new_pos = $entity->{transistion_dest};
         world_mutate_at ($pos, sub {
            my ($data) = @_;

            if ($data->[0] == 50) {
               $data->[0] = 0;
               my $ent = $data->[5];
               $data->[5] = undef;

               world_mutate_at ($new_pos, sub {
                  my ($data) = @_;
                  $data->[0] = 50;
                  $data->[5] = $ent;
                  warn "drone $ent moved from @$pos to @$new_pos\n";
                  drone_check_player_hit ($new_pos, $ent);
                  return 1;
               });

               return 1;

            } else {
               warn "warning: drone $entity at @$pos is not where is hsould be, stopped!\n";
            }

            0
         }, need_entity => 1);
      } else {
         drone_check_player_hit ($pos, $entity);
      }

      return;
   }

   my (@pl) = drone_visible_players ($pos, $entity);

   return unless @pl;
   my $pl = $pl[0]->[0];
   my $new_pos = $pos;

   drone_check_player_hit ($pos, $entity, $pl);

   my $empty =
      Games::VoxEngine::World::get_types_in_cube (
         @{vsubd ($new_pos, 1, 1, 1)}, 3, 0);

   my @empty;
   while (@$empty) {
      my ($pos, $type) = (
         [shift @$empty, shift @$empty, shift @$empty], shift @$empty
      );
      push @empty, $pos;
   }

   if (!@empty) {
      warn "debug: drone $entity is locked in (thats ok :)!\n";
      return;
   }

   my $min = [999999, $empty[0]];
   for my $dlt (
      [0, 0, 1],
      [0, 0, -1],
      [0, 1, 0],
      [0, -1, 0],
      [1, 0, 0],
      [-1, 0, 0]
   ) {
      my $np = vadd ($new_pos, $dlt);

      next unless grep {
         $_->[0] == $np->[0]
         && $_->[1] == $np->[1]
         && $_->[2] == $np->[2]
      } @empty;

      my $diff = vsub ($pl->{data}->{pos}, $np);
      my $dist = vlength ($diff);
      if ($min->[0] > $dist) {
         $min = [$dist, $np];
      }
   }

   $new_pos = $min->[1];

   my $lightness = $entity->{lifetime} / $entity->{orig_lifetime};

   $pl->highlight ($new_pos, 1.5 * $dt, [$lightness, $lightness, $lightness]);
   $entity->{in_transition} = 1;
   $entity->{transition_time} = 1.5 * $dt;
   $entity->{transistion_dest} = $new_pos;
   $pl->{uis}->{prox_warn}->show ("Proximity alert!\nDistance " . int ($min->[0]));
   if (delete $pl->{data}->{kill_drone}) {
      drone_kill ($pos, $entity);
      $pl->{uis}->{prox_warn}->show ("Drone killed!");
   }
}

sub in_auto {
   my ($type) = @_;

   {
      prog => { },
      used_energy => 0,
   }
}

sub ia_auto {
   my ($pl, $pos, $type, $entity) = @_;
   $pl->{uis}->{pcb_prog}->show ($entity);
}

our %DIR2VEC = (
   up       => [ 0,  1,  0],
   down     => [ 0, -1,  0],
   left     => [ 1,  0,  0],
   right    => [-1,  0,  0],
   forward  => [ 0,  0,  1],
   backward => [ 0,  0, -1],
);

sub tmr_auto {
   my ($pos, $entity, $type, $dt) = @_;

   warn "PCB @ @$pos doing something\n";

   my ($pl) = $Games::VoxEngine::Server::World::SRV->get_player ($entity->{player})
      or return;

   my ($pcb_obj) =
      $Games::VoxEngine::Server::RES->get_object_by_type ($type);

   my $pcb = Games::VoxEngine::Server::PCB->new (p => $entity->{prog}, pl => $pl, act => sub {
      my ($op, @args) = @_;
      my $cb = pop @args;

      if ($op eq 'move') {
         my $dir = $DIR2VEC{$args[0]};
         my $new_pos = vadd ($pos, $dir);

         world_mutate_at ($new_pos, sub {
            my ($data) = @_;
            if ($data->[0] != 0) {
               my $obj = $Games::VoxEngine::Server::RES->get_object_by_type ($data->[0]);
               $cb->($obj->{name});
               return 0;
            }

            world_mutate_at ($pos, sub {
               my ($data) = @_;
               if ($data->[0] == 51) {
                  $data->[0] = 0;
                  $data->[3] &= 0xF0; # clear color :)
                  return 1;
               }
               return 0;
            });

            $data->[0] = 51;
            $data->[3] &= 0xF0; # clear color :)
            $data->[5] = $entity;
            warn "pct $entity moved from @$pos to @$new_pos\n";
            $pos = $new_pos; # safety, so we are not moving from the same position again if the PCB code doesn't let the stepper wait...
            $cb->();
            return 1;
         });

      } elsif ($op eq 'vaporize') {
         my $dir = $DIR2VEC{$args[0]};
         my $new_pos = vadd ($pos, $dir);

         world_mutate_at ($new_pos, sub {
            my ($data) = @_;

            $entity->{used_energy} += 1;

            my ($obj) =
               $Games::VoxEngine::Server::RES->get_object_by_type ($data->[0]);

            $data->[0] = 0;
            $data->[3] &= 0xF0; # clear color :)
            $pl->highlight ($new_pos, -$dt, [1, 1, 0]);
            $cb->($obj->{type} != 0 ? $obj->{name} : "");
            return 1;
         });

      } elsif ($op eq 'materialize') {
         my $dir = $DIR2VEC{$args[0]};
         my $new_pos = vadd ($pos, $dir);

         my ($obj) =
            $Games::VoxEngine::Server::RES->get_object_by_name ($args[1]);
         unless ($obj) {
            $pl->msg (1, "PCB Error: No such material: '$args[1]'");
            $cb->("no_such_material");
            return;
         }

         warn "MATERIALIZE OBJECT: $obj | $obj->{type}\n";

         world_mutate_at ($new_pos, sub {
            my ($data) = @_;

            if ($data->[0] == 0) {
               my ($cnt, $ent) = $pl->{inv}->remove ($obj->{type});
               unless ($cnt) {
                  $cb->("empty");
                  return 0;
               }

               $data->[0] = $obj->{type};
               $data->[3] |= $args[2];
               $pl->highlight ($new_pos, $dt, [0, 1, 0]);

               my ($time, $energy, $score) =
                  $Games::VoxEngine::Server::RES->get_type_materialize_values (
                     $obj->{type});

               $entity->{used_energy} += $energy;
               $score /= 10;
               $score = int $score;
               $pl->push_tick_change (score => $score);

               $cb->();
               return 1;

            } else {
               my $obj = $Games::VoxEngine::Server::RES->get_object_by_type ($data->[0]);
               $cb->("blocked" => $obj->{name});
               return 0;
            }

         });

      } elsif ($op eq 'dematerialize') {
         my $dir = $DIR2VEC{$args[0]};
         my $new_pos = vadd ($pos, $dir);

         world_mutate_at ($new_pos, sub {
            my ($data) = @_;

            if ($data->[0] == 0) {
               $cb->("", "");
               return 0;
            }

            my ($obj) =
               $Games::VoxEngine::Server::RES->get_object_by_type ($data->[0]);

            my ($time, $energy, $score) =
               $Games::VoxEngine::Server::RES->get_type_dematerialize_values (
                  $obj->{type});

            if ($pl->{inv}->add ($data->[0], $data->[5] || 1)) {
               $pl->highlight ($new_pos, $dt, [1, 0, 0]);
               $data->[0] = 0;
               $data->[3] &= 0xF0;
               $data->[5] = undef;
               $entity->{used_energy} += $energy;
               $cb->("", $obj->{name});
               return 1;

            } else {
               $cb->("inv_full", $obj->{name});
               return 0;
            }
         }, need_entity => 1);

      } elsif ($op eq 'probe') {
         my $dir = $DIR2VEC{$args[0]};
         my $new_pos = vadd ($pos, $dir);

         world_mutate_at ($new_pos, sub {
            my ($data) = @_;

            if ($data->[0] == 0) {
               $cb->("");
               return 0;
            }

            my ($obj) =
               $Games::VoxEngine::Server::RES->get_object_by_type ($data->[0]);
            $cb->($obj->{name});
            return 0;
         });

      } else {
         warn "DID $op (@args)!\n";
      }
   });

   warn "PCB @ @$pos doing somethingwith $pl->{name}\n";

   my $n = 10;
   while ($n-- > 0) {
      $pcb->{pos} = vfloor ($pos);
      $pcb->{energy_used} = $entity->{used_energy};
      $pcb->{energy_left} = ($pcb_obj->{energy} - $entity->{used_energy});
      my $cmd = $pcb->step ();
      warn "STEP COMMAND: $cmd\n";

      if ($cmd eq 'wait') {
         last;

      } elsif ($cmd eq 'done') {
         $entity->{time_active} = 0;
         last;

      } elsif ($cmd ne '') {
         $entity->{prog}->{wait} = 1;
         $pl->msg (1, "Program error with PCB at @$pos: $cmd");
      }
   }

   if ($pcb_obj->{energy} < $entity->{used_energy}) {
      $pl->msg (1, "PCB at @$pos ran out of energy and vaporized itself.");

      $pl->highlight ($pos, -$dt, [1, 1, 0]);
      world_mutate_at ($pos, sub {
         my ($data) = @_;
         if ($data->[0] == 51) {
            $data->[0] = 0;
            $data->[3] &= 0xF0; # clear color :)
            return 1;
         }
         return 0;
      });
   }
}

=back

=head1 AUTHOR

Robin Redeker, C<< <elmex@ta-sa.org> >>

=head1 COPYRIGHT & LICENSE

Copyright 2011 Robin Redeker, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the terms of the GNU Affero General Public License.

=cut

1;

