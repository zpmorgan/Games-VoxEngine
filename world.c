/*
 * Games::VoxEngine - A 3D Game written in Perl with an infinite and modifiable world.
 * Copyright (C) 2011  Robin Redeker
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as
 * published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */
/* This file implements storage of the world. That means the chunks of the world
 * and information about the possible block types.
 *
 * The chunks of the world are currently saved in a set of nested sparse arrays.
 */
#include <stdio.h>
#include <arpa/inet.h>
#include "vectorlib.c"
#include "queue.c"
#include <assert.h>

#define CHUNK_SIZE      12
#define CHUNKS_P_SECTOR  5
#define MAX_LIGHT_RADIUS 18 // should be enough :)
#define MAX_LIGHT_RADIUS_CHUNKS ( 6 * ((MAX_LIGHT_RADIUS + 1) * 2) * ((MAX_LIGHT_RADIUS + 1) * 2) * ((MAX_LIGHT_RADIUS + 1) * 2))
// => 26^3 * 6 neighbors => ~1.3Mb ringbuffer for queue - should be enough :)

#define CHUNK_ALEN (CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE)
#define POSSIBLE_OBJECTS 4096 // this is the max number of different object types!
#define MAX_MODEL_DIM   6
#define MAX_MODEL_SIZE  (MAX_MODEL_DIM * MAX_MODEL_DIM * MAX_MODEL_DIM)

#define myabs(x) ((x) < 0 ? -(x) : (x))
#define REL_POS2OFFS(x,y,z) (myabs (x) + myabs (y) * CHUNK_SIZE + myabs (z) * (CHUNK_SIZE * CHUNK_SIZE))

#include "world_data_struct.c"

/* Store important information about the block types. This information
 * is used by nearly every algorithm implemented in C currently.
 */
typedef struct _vox_obj_attr {
  double uv[4];
  unsigned short transparent : 1;
  unsigned short blocking    : 1;
  unsigned short has_txt     : 1;
  unsigned short model       : 1;
  unsigned short active      : 1;
  unsigned int   model_dim   : 3;
  unsigned int   model_blocks[MAX_MODEL_SIZE];
} vox_obj_attr;

typedef struct _vox_cell {
   unsigned short type;
   unsigned char  light;
   unsigned char  meta;
   unsigned char  add;  // lower nibble stores color of the block.

   // stores whether the block is visible (used by the renderer later).
   unsigned char  visible : 1;

   unsigned char  pad     : 7; // some padding
} vox_cell;

// Some (unfinished) try to implement storing changes:
#if 0
#define MAX_CHUNK_CHANGES 200
typedef struct _vox_chunk_changed_cell {
    int rx, ry, rz;
} vox_chunk_changed_cell;
#endif

typedef struct _vox_chunk {
    int x, y, z;
    vox_cell cells[CHUNK_ALEN];
    int dirty;
#if 0
    vox_chunk_changed_cell changed_cells[MAX_CHUNK_CHANGES];
    int changes;
#endif
} vox_chunk;

typedef struct _vox_world {
    vox_axis_array *y;
    SV *chunk_change_cb;        // callback for changed chunks.
    SV *active_cell_change_cb;  // callback for changed "active" cells.
} vox_world;

static vox_obj_attr OBJ_ATTR_MAP[POSSIBLE_OBJECTS];
static vox_world WORLD;
static vox_cell neighbour_cell;

typedef struct _vox_light_item {
    int x, y, z;
    unsigned char lv;
} vox_light_item;

// We use a set of two queues, so we can quickly switch back and forth.
static vox_queue *light_upd_queue   = 0;
static vox_queue *light_upd_queue_1 = 0;
static vox_queue *light_upd_queue_2 = 0;

void vox_world_init ()
{
  int i;
  WORLD.y = vox_axis_array_new ();
  memset (OBJ_ATTR_MAP, 0, sizeof (OBJ_ATTR_MAP));
  neighbour_cell.type    = 0;
  neighbour_cell.light   = 0;
  neighbour_cell.add     = 0;
  neighbour_cell.meta    = 0;
  neighbour_cell.visible = 1;
  light_upd_queue_1 =
     vox_queue_new (sizeof (vox_light_item),
                    CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE * 9 * 2);
  light_upd_queue_2 =
     vox_queue_new (sizeof (vox_light_item),
                    CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE * 9 * 2);
}

// Clears light queues for light computation.
void vox_world_light_upd_start ()
{
  light_upd_queue = light_upd_queue_1;
  vox_queue_clear (light_upd_queue_1);
  vox_queue_clear (light_upd_queue_2);
}

// Select light queue used.
void vox_world_light_select_queue (int i)
{
  light_upd_queue = i > 0 ? light_upd_queue_2 : light_upd_queue_1;
}

// Store item in the queue.
void vox_world_light_enqueue (int x, int y, int z, unsigned char light)
{
  vox_light_item it;
  it.x = x;
  it.y = y;
  it.z = z;
  it.lv = light;
  vox_queue_enqueue (light_upd_queue, &it);
  //d// printf ("light upd enqueue %d,%d,%d: %d\n", x, y, z, light);
}

// Freeze current queue state.
void vox_world_light_freeze_queue ()
{
  vox_queue_freeze (light_upd_queue);
}

// Thaw current queue state.
void vox_world_light_thaw_queue ()
{
  vox_queue_thaw (light_upd_queue);
}

// Enqueue neighbor cells.
void vox_world_light_enqueue_neighbours (int x, int y, int z, unsigned char light)
{
  vox_world_light_enqueue (x + 1, y, z, light);
  vox_world_light_enqueue (x - 1, y, z, light);
  vox_world_light_enqueue (x, y + 1, z, light);
  vox_world_light_enqueue (x, y - 1, z, light);
  vox_world_light_enqueue (x, y, z + 1, light);
  vox_world_light_enqueue (x, y, z - 1, light);
}

int vox_world_light_dequeue (int *x, int *y, int *z, unsigned char *light)
{
  vox_light_item *it = vox_queue_dequeue (light_upd_queue);
  if (it)
    {
      *x = it->x;
      *y = it->y;
      *z = it->z;
      *light = it->lv;
      //d// printf ("light upd dequeue %d,%d,%d: %d\n", *x, *y, *z, *light);
    }

  return it != 0;
}

void vox_world_emit_chunk_change (int x, int y, int z)
{
  if (WORLD.chunk_change_cb)
    {
      dSP;
      ENTER;
      SAVETMPS;
      PUSHMARK(SP);
      XPUSHs(sv_2mortal(newSViv (x)));
      XPUSHs(sv_2mortal(newSViv (y)));
      XPUSHs(sv_2mortal(newSViv (z)));
      PUTBACK;
      call_sv (WORLD.chunk_change_cb, G_DISCARD | G_VOID);
      SPAGAIN;
      FREETMPS;
      LEAVE;
    }
}

void vox_world_emit_active_cell_change (int x, int y, int z, vox_cell *c, SV *sv)
{
  if (WORLD.active_cell_change_cb)
    {
      dSP;
      ENTER;
      SAVETMPS;
      PUSHMARK(SP);
      XPUSHs(sv_2mortal(newSViv (x)));
      XPUSHs(sv_2mortal(newSViv (y)));
      XPUSHs(sv_2mortal(newSViv (z)));
      XPUSHs(sv_2mortal(newSViv (c->type)));
      if (sv)
        XPUSHs(sv);
      PUTBACK;
      call_sv (WORLD.active_cell_change_cb, G_DISCARD | G_VOID);
      SPAGAIN;
      FREETMPS;
      LEAVE;
    }
}

vox_obj_attr *vox_world_get_attr (unsigned int type)
{
  return &(OBJ_ATTR_MAP[type]);
}

/* An active cell is a cell that has an entity
 * associated to it in the perl data structure in the server.
 */
int vox_world_is_active (unsigned int type)
{
  vox_obj_attr *a = vox_world_get_attr (type);
  return a->active;
}

void vox_world_set_object_type (
        unsigned int type, unsigned int transparent, unsigned int blocking,
        unsigned int has_txt, unsigned int active,
        double uv0, double uv1, double uv2, double uv3)
{
  vox_obj_attr *oa = vox_world_get_attr (type);
  oa->transparent = transparent;
  oa->blocking    = blocking;
  oa->has_txt     = has_txt;
  oa->active      = active;
  oa->uv[0]       = uv0;
  oa->uv[1]       = uv1;
  oa->uv[2]       = uv2;
  oa->uv[3]       = uv3;
}

void vox_world_set_object_model (unsigned int type, unsigned int dim, AV *blocks)
{
  vox_obj_attr *oa = vox_world_get_attr (type);
  oa->model        = 1;
  oa->model_dim    = dim;

  int midx = av_len (blocks);
  if (midx < 0)
    return;

  int i;
  for (i = 0; i <= midx; i++)
    {
      SV **block = av_fetch (blocks, i, 0);
      if (!block)
        continue;
      oa->model_blocks[i] = SvIV (*block);
    }
}

int vox_set_cell_from_data (vox_cell *c, unsigned char *ptr)
{
 //d//printf ("CELL dATA %p: %02x %02x %02x %02x\n", c, *ptr, *(ptr + 1), *(ptr + 2), *(ptr + 3));
  unsigned short *sptr = (short *) ptr;
  unsigned short blk = ntohs (*sptr);
  unsigned short type  = ((blk & 0xFFF0) >> 4);
  unsigned short light = blk & 0x000F;
  sptr++;
  ptr = (unsigned char *) sptr;
  unsigned char  meta  = *ptr;
  ptr++;
  unsigned char  add   = *ptr;

  int chg = 0;
  if (c->type != type)   chg = 1;
  if (c->light != light) chg = 1;

  c->type  = type;
  c->light = light;
  c->meta  = meta;
  c->add   = add;
  return chg;
}

void vox_get_data_from_cell (vox_cell *c, unsigned char *ptr)
{
  unsigned char *optr = ptr;
  unsigned short *sptr = (short *) ptr;
  unsigned short typelight = ((c->type << 4) & 0xFFF0) | (c->light & 0x000F);
  (*sptr) = htons (typelight);

  sptr++;
  ptr = (unsigned char *) sptr;
  *ptr = c->meta;
  ptr++;
  *ptr = c->add;
 //d//printf ("CELL GET DATA %p: %02x %02x %02x %02x\n", c, *optr, *(optr + 1), *(optr + 2), *(optr + 3));
}

void vox_chunk_clear_changes (vox_chunk *chnk)
{
#if 0
  chnk->changes = 0;
#endif
}

#if 0
void vox_chunk_cell_changed (vox_chunk *chnk, unsigned int x, unsigned int y, unsigned int z) 
{
  if (chnk->changes < MAX_CHUNK_CHANGES)
    {
      vox_chunk_changed_cell *cc = &(chnk->changed_cells[chnk->changes++]);
      cc->rx = x;
      cc->ry = y;
      cc->rz = z;
    }

  chnk->dirty = 1;
}
#endif

vox_cell *vox_chunk_cell_at_rel (vox_chunk *chnk, unsigned int x, unsigned int y, unsigned int z)
{
  unsigned int offs = REL_POS2OFFS (x, y, z);
  return &(chnk->cells[offs]);
}

vox_cell *vox_chunk_cell_at_abs (vox_chunk *chnk, double x, double y, double z)
{
  vec3_init (pos, x, y, z);
  vec3_s_div (pos, CHUNK_SIZE);
  vec3_floor (pos);
  x -= pos[0] * CHUNK_SIZE;
  y -= pos[1] * CHUNK_SIZE;
  z -= pos[2] * CHUNK_SIZE;
  x = floor (x);
  y = floor (y);
  z = floor (z);
  int xi = x, yi = y, zi = z;
  unsigned int offs = REL_POS2OFFS (xi, yi, zi);
  return &(chnk->cells[offs]);
}

int vox_world_cell_transparent (vox_cell *c)
{
  vox_obj_attr *oa = vox_world_get_attr (c->type);
  return oa->transparent;
}


vox_cell *
vox_world_chunk_neighbour_cell (vox_chunk *c, int x, int y, int z, vox_chunk *neigh_chunk)
{
  if (   x < 0 || y < 0 || z < 0
      || x >= CHUNK_SIZE || y >= CHUNK_SIZE || z >= CHUNK_SIZE)
    {
      if (neigh_chunk)
        {
          if (x < 0) x += CHUNK_SIZE;
          if (y < 0) y += CHUNK_SIZE;
          if (z < 0) z += CHUNK_SIZE;
          if (x >= CHUNK_SIZE) x -= CHUNK_SIZE;
          if (y >= CHUNK_SIZE) y -= CHUNK_SIZE;
          if (z >= CHUNK_SIZE) z -= CHUNK_SIZE;
          c = neigh_chunk;
        }
      else
        return &neighbour_cell;
    }

  unsigned int offs = REL_POS2OFFS(x, y, z);

  return &(c->cells[offs]);
}

#define LOAD_NEIGHBOUR_CHUNKS(x,y,z) \
  vox_chunk *top_chunk = vox_world_chunk (x, y + 1, z, 0); \
  vox_chunk *bot_chunk = vox_world_chunk (x, y - 1, z, 0); \
  vox_chunk *left_chunk = vox_world_chunk (x - 1, y, z, 0); \
  vox_chunk *right_chunk = vox_world_chunk (x + 1, y, z, 0); \
  vox_chunk *front_chunk = vox_world_chunk (x, y, z - 1, 0); \
  vox_chunk *back_chunk = vox_world_chunk (x, y, z + 1, 0);

#define GET_NEIGHBOURS(c, x,y,z) \
  vox_cell *top   = vox_world_chunk_neighbour_cell (c, x, y + 1, z, top_chunk); \
  vox_cell *bot   = vox_world_chunk_neighbour_cell (c, x, y - 1, z, bot_chunk); \
  vox_cell *left  = vox_world_chunk_neighbour_cell (c, x - 1, y, z, left_chunk); \
  vox_cell *right = vox_world_chunk_neighbour_cell (c, x + 1, y, z, right_chunk); \
  vox_cell *front = vox_world_chunk_neighbour_cell (c, x, y, z - 1, front_chunk); \
  vox_cell *back  = vox_world_chunk_neighbour_cell (c, x, y, z + 1, back_chunk);


#define GET_LOCAL_NEIGHBOURS(c, x,y,z) \
  vox_cell *top   = vox_world_chunk_neighbour_cell (c, x, y + 1, z, 0); \
  vox_cell *bot   = vox_world_chunk_neighbour_cell (c, x, y - 1, z, 0); \
  vox_cell *left  = vox_world_chunk_neighbour_cell (c, x - 1, y, z, 0); \
  vox_cell *right = vox_world_chunk_neighbour_cell (c, x + 1, y, z, 0); \
  vox_cell *front = vox_world_chunk_neighbour_cell (c, x, y, z - 1, 0); \
  vox_cell *back  = vox_world_chunk_neighbour_cell (c, x, y, z + 1, 0);

/* Calculate the visibility of the blocks. If a block is surrounded by
 * 6 non transparent blocks it's considered non visible.
 */
void vox_world_chunk_calc_visibility (vox_chunk *chnk)
{
  int x, y, z;
  for (z = 0; z < CHUNK_SIZE; z++)
    for (y = 0; y < CHUNK_SIZE; y++)
      for (x = 0; x < CHUNK_SIZE; x++)
        {
          unsigned int offs = REL_POS2OFFS (x, y, z);
          chnk->cells[offs].visible = 0;
        }

  int cnt, cnt2;
  for (z = 0; z < CHUNK_SIZE; z++)
    for (y = 0; y < CHUNK_SIZE; y++)
      for (x = 0; x < CHUNK_SIZE; x++)
        {
          vox_cell *cell = &(chnk->cells[REL_POS2OFFS(x,y,z)]);
          if (cell->type == 0)
            continue;

          // afraid of slowness to not use GET_NEIGHBOURS...
          GET_LOCAL_NEIGHBOURS(chnk, x, y, z);
          if (vox_world_cell_transparent (top))
            { cell->visible = 1; continue; }
          if (vox_world_cell_transparent (bot))
            { cell->visible = 1; continue; }
          if (vox_world_cell_transparent (left))
            { cell->visible = 1; continue; }
          if (vox_world_cell_transparent (right))
            { cell->visible = 1; continue; }
          if (vox_world_cell_transparent (front))
            { cell->visible = 1; continue; }
          if (vox_world_cell_transparent (back))
            { cell->visible = 1; continue; }
        }
}

int vox_world_set_chunk_from_data (vox_chunk *chnk, unsigned char *data, unsigned int len)
{
  unsigned int x, y, z;
  int neigh_chunks = 0;

  for (z = 0; z < CHUNK_SIZE; z++)
    for (y = 0; y < CHUNK_SIZE; y++)
      for (x = 0; x < CHUNK_SIZE; x++)
        {
          unsigned int offs = REL_POS2OFFS (x, y, z);
          assert (len > (offs * 4) + 3);
          int chg = vox_set_cell_from_data (&(chnk->cells[offs]), data + (offs * 4));
          if (chg)
            {
              if (x == 0)
                neigh_chunks |= 0x01; // -1,0,0
              if (y == 0)
                neigh_chunks |= 0x02; // 0,-1,0
              if (z == 0)
                neigh_chunks |= 0x04; // 0,0,-1
              if (x == (CHUNK_SIZE - 1)) // 1,0,0
                neigh_chunks |= 0x08;
              if (y == (CHUNK_SIZE - 1)) // 0,1,0
                neigh_chunks |= 0x10;
              if (z == (CHUNK_SIZE - 1)) // 0,0,1
                neigh_chunks |= 0x20;
            }
        }

  return neigh_chunks;
}

void vox_world_get_chunk_data (vox_chunk *chnk, unsigned char *data)
{
  unsigned int x, y, z;
  for (z = 0; z < CHUNK_SIZE; z++)
    for (y = 0; y < CHUNK_SIZE; y++)
      for (x = 0; x < CHUNK_SIZE; x++)
        {
          unsigned int offs = REL_POS2OFFS (x, y, z);
          vox_get_data_from_cell (&(chnk->cells[offs]), data + (offs * 4));
        }
}

static int chnk_alloc = 0;

vox_chunk *vox_world_chunk (int x, int y, int z, int alloc)
{
  vox_axis_array *xn = (vox_axis_array *) vox_axis_get (WORLD.y, y);
  if (!xn)
    {
      if (alloc)
        {
          xn = vox_axis_array_new ();
          vox_axis_add (WORLD.y, y, xn);
        }
      else
        return 0;
    }

  vox_axis_array *zn = (vox_axis_array *) vox_axis_get (xn, x);
  if (!zn)
    {
      if (alloc)
        {
          zn = vox_axis_array_new ();
          vox_axis_add (xn, x, zn);
        }
      else
        return 0;
    }

  vox_chunk *c = (vox_chunk *) vox_axis_get (zn, z);
  if (alloc && !c)
    {
      c = safemalloc (sizeof (vox_chunk));
      memset (c, 0, sizeof (vox_chunk));
      chnk_alloc++;
      //printf ("ALLOC CHUNK %d %d %d (%d)\n", x, y, z, chnk_alloc);
      c->x = x;
      c->y = y;
      c->z = z;
      vox_axis_add (zn, z, c);
    }

  return c;
}

vox_chunk *vox_world_chunk_at (double x, double y, double z, int alloc)
{
  vec3_init (pos, x, y, z);
  vec3_s_div (pos, CHUNK_SIZE);
  vec3_floor (pos);
  return vox_world_chunk (pos[0], pos[1], pos[2], alloc);
}

void vox_world_purge_chunk (int x, int y, int z)
{
  //printf ("PURGE CHUNK %d %d %d\n", x, y, z);
  vox_axis_array *xn = (vox_axis_array *) vox_axis_get (WORLD.y, y);
  if (!xn)
    return;

  vox_axis_array *zn = (vox_axis_array *) vox_axis_get (xn, x);
  if (!zn)
    return;

  vox_chunk *c = (vox_chunk *) vox_axis_remove (zn, z);
  if (c)
    {
      chnk_alloc--;
      safefree (c);
    }
}

// Haven't tested this function in a long time now. Not sure if it still works :)
void vox_world_dump ()
{
  unsigned int x, y, z;
  printf ("WORLD:\n");
  for (y = 0; y < WORLD.y->len; y++)
    {
      vox_axis_node *any = &(WORLD.y->nodes[y]);
      vox_axis_array *xa = (vox_axis_array *) any->ptr;

      for (x = 0; x < xa->len; x++)
        {
          vox_axis_node *anx = &(xa->nodes[x]);
          vox_axis_array *za = (vox_axis_array *) anx->ptr;
          if (za)
            {
              for (z = 0; z < za->len; z++)
                {
                  vox_axis_node *anz = &(za->nodes[z]);
                  vox_chunk *cnk = (vox_chunk *) anz->ptr;
                  printf ("[%d %d %d] %p(%d,%d,%d)\n", anx->coord, any->coord, anz->coord, anz->ptr, cnk->x, cnk->y, cnk->z);
                }
            }
        }
    }
}
