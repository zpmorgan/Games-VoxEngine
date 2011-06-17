#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <stdio.h>
#include <math.h>

#include "vectorlib.c"
#include "world.c"
#include "world_drawing.c"
#include "render.c"
#include "volume_draw.c"

unsigned char ctr_world_query_get_max_light_of_neighbours (x, y, z)
{
  ctr_cell *above = ctr_world_query_cell_at (x, y + 1, z, 0);
  ctr_cell *below = ctr_world_query_cell_at (x, y - 1, z, 0);
  ctr_cell *left  = ctr_world_query_cell_at (x - 1, y, z, 0);
  ctr_cell *right = ctr_world_query_cell_at (x + 1, y, z, 0);
  ctr_cell *front = ctr_world_query_cell_at (x, y, z - 1, 0);
  ctr_cell *back  = ctr_world_query_cell_at (x, y, z + 1, 0);
  unsigned char l = 0;
  if (above->light > l) l = above->light;
  if (below->light > l) l = below->light;
  if (left->light > l) l = left->light;
  if (right->light > l) l = right->light;
  if (front->light > l) l = front->light;
  if (back->light > l) l = back->light;
  return l;
}

unsigned int ctr_cone_sphere_intersect (double cam_x, double cam_y, double cam_z, double cam_v_x, double cam_v_y, double cam_v_z, double cam_fov, double sphere_x, double sphere_y, double sphere_z, double sphere_rad)
{
  vec3_init(cam,    cam_x, cam_y, cam_z);
  vec3_init(cam_v,  cam_v_x, cam_v_y, cam_v_z);
  vec3_init(sphere, sphere_x, sphere_y, sphere_z);
  vec3_clone(u,  cam);
  vec3_clone(uv, cam_v);
  vec3_clone(d,  sphere);

  vec3_s_mul (uv, sphere_rad / sinl (cam_fov));
  vec3_sub (u, uv);
  vec3_sub (d, u);

  double l = vec3_len (d);

  if (vec3_dot (cam_v, d) >= l * cosl (cam_fov))
    {
       vec3_assign (d, sphere);
       vec3_sub (d, cam);
       l = vec3_len (d);

       if (-vec3_dot (cam_v, d) >= l * sinl (cam_fov))
         return (l <= sphere_rad);
       else
         return 1;
    }
  else
    return 0;
}

MODULE = Games::Construder PACKAGE = Games::Construder::Math PREFIX = ctr_

unsigned int ctr_cone_sphere_intersect (double cam_x, double cam_y, double cam_z, double cam_v_x, double cam_v_y, double cam_v_z, double cam_fov, double sphere_x, double sphere_y, double sphere_z, double sphere_rad);

AV *
ctr_point_aabb_distance (double pt_x, double pt_y, double pt_z, double box_min_x, double box_min_y, double box_min_z, double box_max_x, double box_max_y, double box_max_z)
  CODE:
    vec3_init (pt,   pt_x, pt_y, pt_z);
    vec3_init (bmin, box_min_x, box_min_y, box_min_z);
    vec3_init (bmax, box_max_x, box_max_y, box_max_z);
    unsigned int i;

    double out[3];
    for (i = 0; i < 3; i++)
      {
        out[i] = pt[i];

        if (bmin[i] > bmax[i])
          {
            double swp = bmin[i];
            bmin[i] = bmax[i];
            bmax[i] = swp;
          }

        if (out[i] < bmin[i])
          out[i] = bmin[i];
        if (out[i] > bmax[i])
          out[i] = bmax[i];
      }

    RETVAL = newAV ();
    sv_2mortal ((SV *)RETVAL);

    for (i = 0; i < 3; i++)
      av_push (RETVAL, newSVnv (out[i]));

  OUTPUT:
    RETVAL



AV *
ctr_calc_visible_chunks_at_in_cone (double pt_x, double pt_y, double pt_z, double rad, double cam_x, double cam_y, double cam_z, double cam_v_x, double cam_v_y, double cam_v_z, double cam_fov, double sphere_rad)
  CODE:
    int r = rad;

    RETVAL = newAV ();
    sv_2mortal ((SV *)RETVAL);

    vec3_init (pt, pt_x, pt_y, pt_z);
    vec3_s_div (pt, CHUNK_SIZE);
    vec3_floor (pt);

    int x, y, z;
    for (x = -r; x <= r; x++)
      for (y = -r; y <= r; y++)
        for (z = -r; z <= r; z++)
          {
            vec3_init (chnk,  x, y, z);
            vec3_add (chnk, pt);
            vec3_clone (chnk_p, chnk);

            vec3_sub (chnk, pt);
            if (vec3_len (chnk) < rad)
              {
                vec3_clone (sphere_pos, chnk_p);
                vec3_s_mul (sphere_pos, CHUNK_SIZE);
                sphere_pos[0] += CHUNK_SIZE / 2;
                sphere_pos[1] += CHUNK_SIZE / 2;
                sphere_pos[2] += CHUNK_SIZE / 2;

                if (ctr_cone_sphere_intersect (
                      cam_x, cam_y, cam_z, cam_v_x, cam_v_y, cam_v_z,
                      cam_fov, sphere_pos[0], sphere_pos[1], sphere_pos[2],
                      sphere_rad))
                  {
                    int i;
                    for (i = 0; i < 3; i++)
                      av_push (RETVAL, newSVnv (chnk_p[i]));
                  }
              }
          }

  OUTPUT:
    RETVAL

AV *
ctr_calc_visible_chunks_at (double pt_x, double pt_y, double pt_z, double rad)
  CODE:
    int r = rad;

    RETVAL = newAV ();
    sv_2mortal ((SV *)RETVAL);

    vec3_init (pt, pt_x, pt_y, pt_z);
    vec3_s_div (pt, CHUNK_SIZE);
    vec3_floor (pt);

    int x, y, z;
    for (x = -r; x <= r; x++)
      for (y = -r; y <= r; y++)
        for (z = -r; z <= r; z++)
          {
            vec3_init (chnk,  x, y, z);
            vec3_add (chnk, pt);
            vec3_clone (chnk_p, chnk);
            vec3_sub (chnk, pt);
            if (vec3_len (chnk) < rad)
              {
                int i;
                for (i = 0; i < 3; i++)
                  av_push (RETVAL, newSVnv (chnk_p[i]));
              }
          }

  OUTPUT:
    RETVAL

MODULE = Games::Construder PACKAGE = Games::Construder::Renderer PREFIX = ctr_render_

void *ctr_render_new_geom ();

void ctr_render_clear_geom (void *c);

void ctr_render_draw_geom (void *c);

void ctr_render_free_geom (void *c);

void ctr_render_chunk (int x, int y, int z, void *geom)
  CODE:
    ctr_render_clear_geom (geom);
    ctr_render_chunk (x, y, z, geom);

void
ctr_render_model (unsigned int type, double light, unsigned int xo, unsigned int yo, unsigned int zo, void *geom, int skip, int force_model)
  CODE:
     ctr_render_clear_geom (geom);
     ctr_render_model (type, light, xo, yo, zo, geom, skip, force_model, 1);
     ctr_render_compile_geom (geom);

void ctr_render_init ();

MODULE = Games::Construder PACKAGE = Games::Construder::World PREFIX = ctr_world_

void ctr_world_init (SV *change_cb, SV *cell_change_cb)
  CODE:
     ctr_world_init ();
     SvREFCNT_inc (change_cb);
     WORLD.chunk_change_cb = change_cb;
     WORLD.active_cell_change_cb = cell_change_cb;

SV *
ctr_world_get_chunk_data (int x, int y, int z)
  CODE:
    ctr_chunk *chnk = ctr_world_chunk (x, y, z, 0);
    if (!chnk)
      {
        XSRETURN_UNDEF;
      }

    int len = CHUNK_ALEN * 4;
    unsigned char *data = malloc (sizeof (unsigned char) * len);
    ctr_world_get_chunk_data (chnk, data);

    RETVAL = newSVpv (data, len);
  OUTPUT:
    RETVAL


void ctr_world_set_chunk_data (int x, int y, int z, unsigned char *data, unsigned int len)
  CODE:
    ctr_chunk *chnk = ctr_world_chunk (x, y, z, 1);
    assert (chnk);
    ctr_world_set_chunk_from_data (chnk, data, len);
    int lenc = (CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE) * 4;
    if (lenc != len)
      {
        printf ("CHUNK DATA LEN DOES NOT FIT! %d vs %d\n", len, lenc);
        exit (1);
      }

    ctr_world_chunk_calc_visibility (chnk);

    ctr_world_emit_chunk_change (x, y, z);

    //d// ctr_world_dump ();

    /*
    unsigned char *datac = malloc (sizeof (unsigned char) * lenc);
    ctr_world_get_chunk_data (chnk, datac);
    int i;
    for (i = 0; i < lenc; i++)
      {
        if (data[i] != datac[i])
          {
            printf ("BUG! AT %d %x %d\n", i, data[i], datac[i]);
            exit (1);
          }
      }
    */

int ctr_world_is_solid_at (double x, double y, double z)
  CODE:
    RETVAL = 0;

    ctr_chunk *chnk = ctr_world_chunk_at (x, y, z, 0);
    if (chnk)
      {
        ctr_cell *c = ctr_chunk_cell_at_abs (chnk, x, y, z);
        ctr_obj_attr *attr = ctr_world_get_attr (c->type);
        RETVAL = attr ? attr->blocking : 0;
      }
  OUTPUT:
    RETVAL

void ctr_world_set_object_type (unsigned int type, unsigned int transparent, unsigned int blocking, unsigned int has_txt, double uv0, double uv1, double uv2, double uv3);

void ctr_world_set_object_model (unsigned int type, unsigned int dim, AV *blocks);

AV *
ctr_world_at (double x, double y, double z)
  CODE:
    RETVAL = newAV ();
    sv_2mortal ((SV *)RETVAL);

    ctr_chunk *chnk = ctr_world_chunk_at (x, y, z, 0);
    if (chnk)
      {
        ctr_cell *c = ctr_chunk_cell_at_abs (chnk, x, y, z);
        av_push (RETVAL, newSViv (c->type));
        av_push (RETVAL, newSViv (c->light));
        av_push (RETVAL, newSViv (c->meta));
        av_push (RETVAL, newSViv (c->add));
        av_push (RETVAL, newSViv (c->visible));
      }

  OUTPUT:
    RETVAL

AV *
ctr_world_chunk_visible_faces (int x, int y, int z)
  CODE:
    ctr_chunk *chnk = ctr_world_chunk (x, y, z, 0);

    RETVAL = newAV ();
    sv_2mortal ((SV *)RETVAL);

    for (z = 0; z < CHUNK_SIZE; z++)
      for (y = 0; y < CHUNK_SIZE; y++)
        for (x = 0; x < CHUNK_SIZE; x++)
          {
            if (chnk->cells[REL_POS2OFFS(x, y, z)].visible)
              {
                av_push (RETVAL, newSViv (chnk->cells[REL_POS2OFFS(x, y, z)].type));
                av_push (RETVAL, newSVnv (x));
                av_push (RETVAL, newSVnv (y));
                av_push (RETVAL, newSVnv (z));
              }
          }

  OUTPUT:
    RETVAL

void
ctr_world_test_binsearch ()
  CODE:
    ctr_axis_array arr;
    arr.alloc = 0;

    printf ("TESTING...\n");
    ctr_axis_array_insert_at (&arr, 0,  10, (void *) 10);
    ctr_axis_array_insert_at (&arr, 1, 100, (void *) 100);
    ctr_axis_array_insert_at (&arr, 2, 320, (void *) 320);
    ctr_axis_array_insert_at (&arr, 1,  11, (void *) 11);
    ctr_axis_array_insert_at (&arr, 0,  9, (void *) 9);
    ctr_axis_array_insert_at (&arr, 5,  900, (void *) 900);
    ctr_axis_array_dump (&arr);

    printf ("SERACHING...\n");
    ctr_axis_node *an = 0;
    int idx = ctr_axis_array_find (&arr, 12, &an);
    printf ("IDX %d %p\n",idx, an);
    idx = ctr_axis_array_find (&arr, 13, &an);
    printf ("IDX %d %p\n",idx, an);
    idx = ctr_axis_array_find (&arr, 1003, &an);
    printf ("IDX %d %p\n",idx, an);
    idx = ctr_axis_array_find (&arr, 11, &an);
    printf ("IDX %d %p\n",idx, an);
    idx = ctr_axis_array_find (&arr, 3, &an);
    printf ("IDX %d %p\n",idx, an);
    idx = ctr_axis_array_find (&arr, 0, &an);
    printf ("IDX %d %p\n",idx, an);
    idx = ctr_axis_array_find (&arr, 320, &an);
    printf ("IDX %d %p\n",idx, an);

    void *ptr = ctr_axis_array_remove_at (&arr, 2);
    printf ("removed %p\n", ptr),
    ctr_axis_array_dump (&arr);
    ptr = ctr_axis_array_remove_at (&arr, 0);
    printf ("removed %p\n", ptr),
    ctr_axis_array_dump (&arr);
    ptr = ctr_axis_array_remove_at (&arr, 3);
    printf ("removed %p\n", ptr),
    ctr_axis_array_dump (&arr);

    ctr_axis_remove (&arr, 100);
    ctr_axis_remove (&arr, 320);
    ctr_axis_remove (&arr, 10);
    ctr_axis_array_dump (&arr);
    ctr_axis_add (&arr, 9, (void *) 9);
    ctr_axis_add (&arr, 320, (void *) 320);
    idx = ctr_axis_array_find (&arr, 11, &an);
    printf ("IDX %d %p\n",idx, an);
    idx = ctr_axis_array_find (&arr, 0, &an);
    printf ("IDX %d %p\n",idx, an);
    idx = ctr_axis_array_find (&arr, 400, &an);
    printf ("IDX %d %p\n",idx, an);
    ctr_axis_add (&arr, 11, (void *) 11);
    ctr_axis_add (&arr, 10, (void *) 10);
    ctr_axis_add (&arr, 0, (void *) 0);
    ctr_axis_add (&arr, 50, (void *) 50);
    ctr_axis_array_dump (&arr);
    ctr_axis_remove (&arr, 12);
    ctr_axis_remove (&arr, 50);
    ctr_axis_remove (&arr, 0);
    ctr_axis_remove (&arr, 320);
    ctr_axis_array_dump (&arr);

    ctr_world_init ();
    printf ("WORLD TEST\n\n");

    printf ("*********** ADD 0, 0, 0\n");
    ctr_chunk *chnk = ctr_world_chunk (0, 0, 0, 1);
    assert (chnk);
    ctr_world_dump ();
    printf ("*********** ADD 0, 0, 1\n");
    chnk = ctr_world_chunk (0, 0, 1, 1);
    assert (chnk);
    ctr_world_dump ();
    printf ("*********** ADD 2, 3, 1\n");
    chnk = ctr_world_chunk (2, 3, 1, 1);
    assert (chnk);
    ctr_world_dump ();


void ctr_world_query_load_chunks ();

void ctr_world_query_set_at (unsigned int rel_x, unsigned int rel_y, unsigned int rel_z, AV *cell)
  CODE:
    ctr_world_query_set_at_pl (rel_x, rel_y, rel_z, cell);

void ctr_world_query_set_at_abs (unsigned int rel_x, unsigned int rel_y, unsigned int rel_z, AV *cell)
  CODE:
    ctr_world_query_abs2rel (&rel_x, &rel_y, &rel_z);
    ctr_world_query_set_at_pl (rel_x, rel_y, rel_z, cell);

void ctr_world_query_unallocated_chunks (AV *chnkposes);

void ctr_world_query_setup (int x, int y, int z, int ex, int ey, int ez);

int ctr_world_query_desetup (int no_update = 0);

AV *ctr_world_find_free_spot (int x, int y, int z, int with_floor)
  CODE:
    vec3_init (pos, x, y, z);
    vec3_s_div (pos, CHUNK_SIZE);
    vec3_floor (pos);
    int chnk_x = pos[0],
        chnk_y = pos[1],
        chnk_z = pos[2];

    ctr_world_query_setup (
      chnk_x - 2, chnk_y - 2, chnk_z - 2,
      chnk_x + 2, chnk_y + 2, chnk_z + 2
    );

    ctr_world_query_load_chunks ();

    int cx = x, cy = y, cz = z;
    ctr_world_query_abs2rel (&cx, &cy, &cz);

    RETVAL = newAV ();
    sv_2mortal ((SV *)RETVAL);

    int rad;
    int ix, iy, iz;
    int found = 0;
    for (rad = 0; !found && rad < ((CHUNK_SIZE * 2) - 3); rad++) // -3 safetymargin
      for (ix = -rad; !found && ix <= rad; ix++)
        for (iy = -rad; !found && iy <= rad; iy++)
          for (iz = -rad; !found && iz <= rad; iz++)
            {
              int dx = ix + cx,
                  dy = iy + cy,
                  dz = iz + cz;

              ctr_cell *cur = ctr_world_query_cell_at (dx, dy, dz, 0);
              ctr_obj_attr *attr = ctr_world_get_attr (cur->type);
              if (attr->blocking)
                continue;

              cur = ctr_world_query_cell_at (dx, dy + 1, dz, 0);
              attr = ctr_world_get_attr (cur->type);
              if (attr->blocking)
                continue;

              cur = ctr_world_query_cell_at (dx, dy - 1, dz, 0);
              attr = ctr_world_get_attr (cur->type);
              if (with_floor && !attr->blocking)
                continue;

              av_push (RETVAL, newSViv (x + ix));
              av_push (RETVAL, newSViv (y + iy));
              av_push (RETVAL, newSViv (z + iz));
              found = 1;
            }

  OUTPUT:
    RETVAL

AV *ctr_world_get_types_in_cube (int x, int y, int z, int size)
  CODE:
    vec3_init (pos1, x, y, z);
    vec3_s_div (pos1, CHUNK_SIZE);
    vec3_floor (pos1);

    vec3_init (pos2, x + size, y + size, z + size);
    vec3_s_div (pos2, CHUNK_SIZE);
    vec3_floor (pos2);

    ctr_world_query_setup (
      (int) pos1[0], (int) pos1[1], (int) pos1[2],
      (int) pos2[0], (int) pos2[1], (int) pos2[2]
    );

    ctr_world_query_load_chunks ();

    int cx = x, cy = y, cz = z;
    ctr_world_query_abs2rel (&cx, &cy, &cz);

    RETVAL = newAV ();
    sv_2mortal ((SV *)RETVAL);

    int dx, dy, dz;
    for (dx = 0; dx < size; dx++)
      for (dy = 0; dy < size; dy++)
        for (dz = 0; dz < size; dz++)
          {
            ctr_cell *cur = ctr_world_query_cell_at (cx + dx, cy + dy, cz + dz, 0);
            av_push (RETVAL, newSViv (cur->type));
          }

    ctr_world_query_desetup (1);

  OUTPUT:
    RETVAL

AV *ctr_world_get_pattern (int x, int y, int z, int mutate)
  CODE:
    vec3_init (pos, x, y, z);
    vec3_s_div (pos, CHUNK_SIZE);
    vec3_floor (pos);
    int chnk_x = pos[0],
        chnk_y = pos[1],
        chnk_z = pos[2];

    ctr_world_query_setup (
      chnk_x - 1, chnk_y - 1, chnk_z - 1,
      chnk_x + 1, chnk_y + 1, chnk_z + 1
    );

    ctr_world_query_load_chunks ();

    RETVAL = newAV ();
    sv_2mortal ((SV *)RETVAL);

    // calc relative size inside chunks:
    int cx = x, cy = y, cz = z;
    ctr_world_query_abs2rel (&cx, &cy, &cz);

    printf ("QUERY AT %d %d %d\n", cx, cy, cz);

    // find lowest cx/cz coord with constr. floor
    ctr_cell *cur = ctr_world_query_cell_at (cx, cy, cz, 0);
    while (cur->type == 36)
      {
        cx--;
        printf ("CX %d\n", cx);
        cur = ctr_world_query_cell_at (cx, cy, cz, 0);
      }

    cx++;
    cur = ctr_world_query_cell_at (cx, cy, cz, 0);
    while (cur->type == 36)
      {
        cz--;
        printf ("CZ %d\n", cz);
        cur = ctr_world_query_cell_at (cx, cy, cz, 0);
      }
    cz++;

    printf ("MINX FOUND %d %d\n", cx, cz);

    // find out how large the floor is
    int dim;
    for (dim = 4; dim >= 1; dim--)
      {
        int no_floor = 0;

        int dx, dz;
        for (dx = 0; dx < dim; dx++)
          for (dz = 0; dz < dim; dz++)
            {
              ctr_cell *cur = ctr_world_query_cell_at (cx + dx, cy, cz + dz, 0);
              printf ("TXT[%d] %d %d %d: %d\n", dim, cx + dx, cy, cz + dz, cur->type);
              if (cur->type != 36)
                no_floor = 1;
            }
        if (!no_floor)
          break;
      }

    if (dim <= 0)
      {
        ctr_world_query_desetup (1);
        XSRETURN_UNDEF;
      }

    printf ("floor dimension: %d\n", dim);
    // next: search first x/z coord with a block over it
    int min_x = 100, min_y = 100, min_z = 100, max_x = 0, max_y = 0, max_z = 0;
    int dx, dy, dz;
    int fnd = 0;
    for (dy = 1; dy <= dim; dy++)
      for (dz = 0; dz < dim; dz++)
        for (dx = 0; dx < dim; dx++)
          {
            int ix = dx + cx,
                iy = dy + cy,
                iz = dz + cz;
            cur = ctr_world_query_cell_at (ix, iy, iz, 0);
            if (cur->type != 0)
              {
                if (min_x > ix) min_x = ix;
                if (min_y > iy) min_y = iy;
                if (min_z > iz) min_z = iz;
              }
          }

    for (dy = 1; dy <= dim; dy++)
      for (dz = 0; dz < dim; dz++)
        for (dx = 0; dx < dim; dx++)
          {
            int ix = dx + cx,
                iy = dy + cy,
                iz = dz + cz;
            cur = ctr_world_query_cell_at (ix, iy, iz, 0);
            if (cur->type != 0)
              {
                if (max_x < ix) max_x = ix;
                if (max_y < iy) max_y = iy;
                if (max_z < iz) max_z = iz;
              }
          }

    dim = 0;
    if (((max_x - min_x) + 1) > dim)
      dim = (max_x - min_x) + 1;
    if (((max_y - min_y) + 1) > dim)
      dim = (max_y - min_y) + 1;
    if (((max_z - min_z) + 1) > dim)
      dim = (max_z - min_z) + 1;

    printf ("FOUND MIN MAX %d %d %d, %d %d %d, dimension: %d\n", min_x, min_y, min_z, max_x, max_y, max_z, dim);

    if (!mutate)
      av_push (RETVAL, newSViv (dim));

    int blk_nr = 1;
    for (dy = 0; dy < dim; dy++)
      for (dz = 0; dz < dim; dz++)
        for (dx = 0; dx < dim; dx++)
          {
            int ix = min_x + dx,
                iy = min_y + dy,
                iz = min_z + dz;

            // outside construction pad:
            if (ix > max_x || iy > max_y || iz > max_z)
              {
                blk_nr++; // but is just empty space of pattern
                continue;
              }

            cur = ctr_world_query_cell_at (ix, iy, iz, 0);
            if (cur->type != 0)
              {
                if (mutate == 1)
                  {
                    av_push (RETVAL, newSViv ((chnk_x - 1) * CHUNK_SIZE + ix));
                    av_push (RETVAL, newSViv ((chnk_y - 1) * CHUNK_SIZE + iy));
                    av_push (RETVAL, newSViv ((chnk_z - 1) * CHUNK_SIZE + iz));
                  }
                else
                  {
                    av_push (RETVAL, newSViv (blk_nr));
                    av_push (RETVAL, newSViv (cur->type));
                  }
              }

            blk_nr++;
          }

    ctr_world_query_desetup (1);

  OUTPUT:
    RETVAL


#define DEBUG_LIGHT 0

void ctr_world_flow_light_query_setup (int minx, int miny, int minz, int maxx, int maxy, int maxz)
  CODE:
    vec3_init (min_pos, minx, miny, minz);
    vec3_s_div (min_pos, CHUNK_SIZE);
    vec3_floor (min_pos);
    vec3_init (max_pos, maxx, maxy, maxz);
    vec3_s_div (max_pos, CHUNK_SIZE);
    vec3_floor (max_pos);

    ctr_world_query_setup (
      min_pos[0] - 2, min_pos[1] - 2, min_pos[2] - 2,
      max_pos[0] + 2, max_pos[1] + 2, max_pos[2] + 2
    );

    ctr_world_query_load_chunks ();

void ctr_world_flow_light_at (int x, int y, int z)
  CODE:
    ctr_world_query_abs2rel (&x, &y, &z);

    ctr_world_light_upd_start ();

    ctr_cell *cur = ctr_world_query_cell_at (x, y, z, 0);

    int light_up = 0;

    // Invariant: The possible radius lighted by a light should be
    // inside the query_setup() loaded chunks, which are 2 chunks in each
    // possible direction from the center chunk. That are 5x5x5 chunks
    // (Which is a whole sector of cells).

    if (ctr_world_cell_transparent (cur)) // a transparent cell has changed
      {
        unsigned char l = ctr_world_query_get_max_light_of_neighbours (x, y, z);
        if (l > 0) l--;
        printf ("transparent cell at %d,%d,%d has light %d, neighbors say: %d\n", x, y, z, (int) cur->light, (int) l);
        if (cur->light < l)
          { // if the transparent cell is too dark, flow in light from neigbors
            // and tell all neighbors to check if they are maybe lighted
            // by my new light
            ctr_cell *cur = ctr_world_query_cell_at (x, y, z, 1);
            cur->light = l; // make me brighter and run light_up algo
            if (l > 0) l--;
            light_up = 1;
            ctr_world_light_enqueue_neighbours (x, y, z, l);
          }
        else if (cur->light > l) // we are brighter then the neighbors
          {
            // we were the light, so we should add us to the
            // light_down queue, because we might need to let
            // other light sources light through!
            light_up = 0;
            ctr_world_light_enqueue (x, y, z, cur->light);
          }
        else // cur->light == l
          {
            // we are transparent and have the light we should have
            // so we don't need to change anything.
            // BUT:
            //    still force update :) FIXME: This should maybe
            //    be done by ChunkManager
            ctr_world_query_cell_at (x, y, z, 1);
            return; // => no change, so no change for anyone else
          }
      }
    else // oh, a (light) blocking cell has been set!
      {
        ctr_cell *cur = ctr_world_query_cell_at (x, y, z, 1);

        // FIXME: add other lamp types here too:
        if (cur->type == 40) // was a light: light it!
          {
            cur->light = 15;
            light_up = 1; // propagate our light!
            ctr_world_light_enqueue_neighbours (x, y, z, cur->light - 1);
          }
        else // oh boy, we will become darker, we are a intransparent block!
          {
            light_up = 0; // make it darker
            unsigned char l = cur->light;
            cur->light = 0; // we are blocking light, so we are dark
            // let the neighbors check if they were lit possibly by me
            ctr_world_light_enqueue_neighbours (x, y, z, l - 1);
          }
      }
#if DEBUG_LIGHT
    printf ("light up: %d\n", light_up);
#endif

    // light_up == 1 means: light value in queue says: you should be this bright!
    // light_up == 0 means: light value in queue says: do you still have a
    //                      neighbor thats at least this bright?

    unsigned char new_value = 0;
    while (ctr_world_light_dequeue (&x, &y, &z, &new_value))
      {
        cur = ctr_world_query_cell_at (x, y, z, 0);
        if (!ctr_world_cell_transparent (cur))
          continue; // ignore blocks that can't be lit

        if (light_up)
          { // on light up, tell the cells to update them to the new
            // value if it makes them brighter. if it makes them brighter,
            // the cells will distribute the (by 1 lower) light to the neighbors
            if (cur->light < new_value)
              {
#if DEBUG_LIGHT
                printf ("light up got %d,%d,%d: %d, me %d\n",
                        x, y, z, new_value, cur->light);
#endif
                cur = ctr_world_query_cell_at (x, y, z, 1);
                cur->light = new_value;
                if (new_value > 0) new_value--;
                // enqueue neighbors for update with lower light level:
                ctr_world_light_enqueue_neighbours (x, y, z, new_value);
              }
          }
        else
          { // on light down is split into two passes:
            //   1st pass: going from the seed cell's we black out
            //             all cells which were lit by the seed(s)
            //             (the seeds are usually either the previous light
            //             source itself or maybe the neighbors of a block
            //             that potentially occludes the light)
            //             in other words: the first pass should just walk down
            //             the light cone of the seeds and black them out
            //
            //   2nd pass: With all possibly completely dark cells being dark
            //             we revisit every darkened cell and compute their light
            //             from their neighbor cells. We repeat this until
            //             no light value changes anymore.
            //
            //   Bugs should be virtually non-visible, every changed cell from
            //   the first pass is repaired in the second pass anyway!

            unsigned char l = ctr_world_query_get_max_light_of_neighbours (x, y, z);
            if (l > 0) l--;
#if DEBUG_LIGHT
            printf ("light down at %d,%d,%d, me: %d, old neigh: %d cur neigh: %d\n", x, y, z, cur->light, new_value, l);
#endif
            if (cur->light <= new_value && cur->light > l)
              // we are not brighter than the now dark neighbor
              // and we are lighter than we would be lit by our neighbors
              {
                // become dark too and enqueue neighbors for update
                cur = ctr_world_query_cell_at (x, y, z, 1);
                new_value = cur->light;
                cur->light = 0;
                if (new_value > 0) new_value--;
                // enqueue neighbors for update:
                ctr_world_light_enqueue_neighbours (x, y, z, new_value);

                // enqueue ourself for the next passes, where we light up
                // the zero light level by ambient light
                ctr_world_light_select_queue (1);
                ctr_world_light_enqueue (x, y, z, 0);
                ctr_world_light_select_queue (0);
              }
          }
      }

    if (!light_up)
      {
        // extra pass for light-down, to reflow other light sources light

        int cur_queue = 0;

        // select queue for light-re-distribution
        int change = 1;
        int pass = 0;
        while (change)
          {
            change = 0;
            pass++;
#if DEBUG_LIGHT
            printf ("START RELIGHT PASS %d\n", pass);
#endif
            // swap queue
            ctr_world_light_select_queue (cur_queue = !cur_queue);
            // recompute light for every cell in the queue
            while (ctr_world_light_dequeue (&x, &y, &z, &new_value))
              {
                cur = ctr_world_query_cell_at (x, y, z, 0);
                unsigned char l = ctr_world_query_get_max_light_of_neighbours (x, y, z);
                if (l > 0) l--;
#if DEBUG_LIGHT
                printf ("[%d] relight at %d,%d,%d, me: %d, cur neigh: %d\n", pass, x, y, z, cur->light, l);
#endif
                // if the current cell is too dark, relight it
                if (cur->light < l)
                  {
                    cur = ctr_world_query_cell_at (x, y, z, 1);
                    cur->light = l;
                    change = 1;
                  }

                // we are in an iterative process, to re-add all cells
                // right back to the other queue for the next pass.
                // just because our cell didn't change doesn't mean it won't
                // in the next pass.
                ctr_world_light_select_queue (!cur_queue);
                ctr_world_light_enqueue (x, y, z, 0);
                ctr_world_light_select_queue (cur_queue);
              }
          }
      }

 //   ctr_world_query_desetup ();

MODULE = Games::Construder PACKAGE = Games::Construder::VolDraw PREFIX = vol_draw_

void vol_draw_init ();

void vol_draw_alloc (unsigned int size);

void vol_draw_set_op (unsigned int op);

void vol_draw_set_dst (unsigned int i);

void vol_draw_set_src (unsigned int i);

void vol_draw_set_dst_range (double a, double b);

void vol_draw_set_src_range (double a, double b);

void vol_draw_set_src_blend (double r);

void vol_draw_val (double val);

void vol_draw_dst_self ();

void vol_draw_subdiv (int type, float x, float y, float z, float size, float shrink_fact, int lvl);

void vol_draw_fill_simple_noise_octaves (unsigned int seed, unsigned int octaves, double factor, double persistence);

void vol_draw_menger_sponge_box (float x, float y, float z, float size, unsigned short lvl);

void vol_draw_cantor_dust_box (float x, float y, float z, float size, unsigned short lvl);

void vol_draw_sierpinski_pyramid (float x, float y, float z, float size, unsigned short lvl);

void vol_draw_self_sim_cubes_hash_seed (float x, float y, float z, float size, unsigned int corners, unsigned int seed, unsigned short lvl);

void vol_draw_map_range (float a, float b, float x, float y);

void vol_draw_copy (void *dst_arr);

void vol_draw_histogram_equalize (int buckets, double a, double b);

int vol_draw_count_in_range (double a, double b)
  CODE:
    int c = 0;
    int x, y, z;
    for (x = 0; x < DRAW_CTX.size; x++)
      for (y = 0; y < DRAW_CTX.size; y++)
        for (z = 0; z < DRAW_CTX.size; z++)
          {
            double v = DRAW_DST (x, y, z);
            if (v >= a && v < b)
              c++;
          }
    RETVAL = c;
  OUTPUT:
    RETVAL


AV *vol_draw_to_perl ()
  CODE:
    RETVAL = newAV ();
    sv_2mortal ((SV *)RETVAL);
    av_push (RETVAL, newSViv (DRAW_CTX.size));

    int x, y, z;
    for (x = 0; x < DRAW_CTX.size; x++)
      for (y = 0; y < DRAW_CTX.size; y++)
        for (z = 0; z < DRAW_CTX.size; z++)
          av_push (RETVAL, newSVnv (DRAW_DST (x, y, z)));

  OUTPUT:
    RETVAL

void vol_draw_dst_to_world (int sector_x, int sector_y, int sector_z, AV *range_map)
  CODE:
    int cx = sector_x * CHUNKS_P_SECTOR,
        cy = sector_y * CHUNKS_P_SECTOR,
        cz = sector_z * CHUNKS_P_SECTOR;

    ctr_world_query_setup (
      cx, cy, cz,
      cx + (CHUNKS_P_SECTOR - 1),
      cy + (CHUNKS_P_SECTOR - 1),
      cz + (CHUNKS_P_SECTOR - 1)
    );

    ctr_world_query_load_chunks ();
    int x, y, z;
    for (x = 0; x < DRAW_CTX.size; x++)
      for (y = 0; y < DRAW_CTX.size; y++)
        for (z = 0; z < DRAW_CTX.size; z++)
          {
            ctr_cell *cur = ctr_world_query_cell_at (x, y, z, 1);
            double v = DRAW_DST(x, y, z);

            int al = av_len (range_map);
            int i;
            for (i = 0; i <= al; i += 3)
              {
                SV **a = av_fetch (range_map, i, 0);
                SV **b = av_fetch (range_map, i + 1, 0);
                SV **t = av_fetch (range_map, i + 2, 0);
                if (!a || !b || !v)
                  continue;

                double av = SvNV (*a),
                       bv = SvNV (*b);
                if (v >= av && v < bv)
                  cur->type = SvIV (*t);
              }
          }

MODULE = Games::Construder PACKAGE = Games::Construder::Region PREFIX = region_

void *region_new_from_vol_draw_dst ()
  CODE:
    double *region =
       malloc ((sizeof (double) * DRAW_CTX.size * DRAW_CTX.size * DRAW_CTX.size) + 1);
    RETVAL = region;

    printf ("REG %p %d\n", region, DRAW_CTX.size);
    region[0] = DRAW_CTX.size;
    region++;
    vol_draw_copy (region);
    printf ("REGVALUES: %f\n", region[0]);
    printf ("REGVALUES: %f\n", region[1]);
    printf ("REGVALUES: %f\n", region[99]);
    printf ("REGVALUES: %f\n", region[99 * 100]);
    printf ("REGVALUES: %f\n", region[100]);

  OUTPUT:
    RETVAL

unsigned int region_get_sector_seed (int x, int y, int z)
  CODE:
    RETVAL = map_coord2int (x, y, z);
  OUTPUT:
    RETVAL

AV *region_get_nearest_sector_in_range (void *reg, int x, int y, int z, double a, double b)
  CODE:
     double *region = reg;
     int reg_size = region[0];
     region++;

     RETVAL = newAV ();
     sv_2mortal ((SV *)RETVAL);

     int rad;
     for (rad = 1; rad < (reg_size / 2); rad++)
       {
         int fnd = 0;
         int dx, dy, dz;
         for (dx = -rad; dx <= rad; dx++)
           for (dy = -rad; dy <= rad; dy++)
             for (dz = -rad; dz <= rad; dz++)
               {
                 int ox = x + dx,
                     oy = y + dy,
                     oz = z + dz;
                 if (ox < 0) ox = -ox;
                 if (oy < 0) oy = -oy;
                 if (oz < 0) oz = -oz;
                 ox %= reg_size;
                 oy %= reg_size;
                 oz %= reg_size;
                 double v = region[ox + oy * reg_size + oz * reg_size * reg_size];
                 if (v < a || v >= b)
                   continue;

                 av_push (RETVAL, newSViv (x + dx));
                 av_push (RETVAL, newSViv (y + dy));
                 av_push (RETVAL, newSViv (z + dz));
                 fnd = 1;
               }

         if (fnd)
           break;
       }

  OUTPUT:
    RETVAL

double region_get_sector_value (void *reg, int x, int y, int z)
  CODE:
    if (!reg)
      XSRETURN_UNDEF;

    double *region = reg;
    int reg_size = region[0];
    region++;

    if (x < 0) x = -x;
    if (y < 0) y = -y;
    if (z < 0) z = -z;
    x %= reg_size;
    y %= reg_size;
    z %= reg_size;

    double xv = region[x + y * reg_size + z * reg_size * reg_size];
    //d// printf ("REGGET %p %d %d %d %d => %f\n", reg, reg_size, x, y, z, xv);
    RETVAL = xv;

  OUTPUT:
    RETVAL
