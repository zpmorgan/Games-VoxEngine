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
/* This file contains the implementation of the data structure
 * that will store the chunks of the world.
 * It's basically a primitively implemented sparse array for each
 * coordinate axis. The nesting of this arrays is done in world.c.
 */

typedef struct _vox_axis_node {
    int coord;
    void *ptr;
} vox_axis_node;

typedef struct _vox_axis_array {
   vox_axis_node *nodes;
   unsigned int len;
   unsigned int alloc;
} vox_axis_array;


void vox_axis_array_grow (vox_axis_array *arr, unsigned int min_size)
{
  if (arr->alloc > min_size)
    return;

  if (arr->alloc == 0)
    {
      arr->alloc = 64;
      arr->nodes = safemalloc (sizeof (vox_axis_node) * arr->alloc);
      memset (arr->nodes, 0, sizeof (vox_axis_node) * arr->alloc);
      arr->len = 0;
      return;
    }

  unsigned int oa = arr->alloc;

  while (arr->alloc < min_size)
    arr->alloc *= 2;

  vox_axis_node *newnodes = safemalloc (sizeof (vox_axis_node) * arr->alloc);
  assert (newnodes);
  memset (newnodes, 0, sizeof (vox_axis_node) * arr->alloc);
  memcpy (newnodes, arr->nodes, sizeof (vox_axis_node) * oa);
  safefree (arr->nodes);
  arr->nodes = newnodes;
}

vox_axis_array *vox_axis_array_new ()
{
  vox_axis_array *na = safemalloc (sizeof (vox_axis_array));
  memset (na, 0, sizeof (vox_axis_array));
  na->len = 0;
  na->alloc = 0;
  vox_axis_array_grow (na, 1);
  return na;
}

void vox_axis_array_dump (vox_axis_array *arr)
{
  int i;
  //d// printf ("alloc: %d\n", arr->alloc);
  for (i = 0; i < arr->len; i++)
    printf ("%d: %d (%p)\n", i, arr->nodes[i].coord, arr->nodes[i].ptr);
}


void vox_axis_array_insert_at (vox_axis_array *arr, unsigned int idx, int coord, void *ptr)
{
  if ((arr->len + 1) >= arr->alloc)
    vox_axis_array_grow (arr, arr->len + 1);

  assert (arr->alloc >= arr->len + 1);

  vox_axis_node *an = 0;
  if (arr->len > idx)
    {
      unsigned int tail_len = arr->len - idx;
      memmove (arr->nodes + idx + 1, arr->nodes + idx,
               sizeof (vox_axis_node) * tail_len);
    }

  an = &(arr->nodes[idx]);

  an->coord = coord;
  an->ptr   = ptr;
  arr->len++;
}

void *vox_axis_array_remove_at (vox_axis_array *arr, unsigned int idx)
{
  assert (idx < arr->len);
  void *ptr = arr->nodes[idx].ptr;

  if ((idx + 1) < arr->len)
    {
      unsigned int tail_len = arr->len - (idx + 1);
      memmove (arr->nodes + idx, arr->nodes + idx + 1,
                sizeof (vox_axis_node) * tail_len);
    }

  arr->len--;
  return ptr;
}

unsigned int vox_axis_array_find (vox_axis_array *arr, int coord, vox_axis_node **node)
{
  *node = 0;
  if (arr->len == 0)
    return 0;

  int min = 0;
  int max = arr->len; // include last free index

  int mid = 0;
  while (min < max)
    {
      mid = min + (max - min) / 2;
      if (mid == arr->len || arr->nodes[mid].coord >= coord)
        max = mid;
      else
        min = mid + 1;
    }

  if (min < arr->len && arr->nodes[min].coord == coord)
    *node = &(arr->nodes[min]);

  return min;
}

void *vox_axis_get (vox_axis_array *arr, int coord)
{
  vox_axis_node *node = 0;
  vox_axis_array_find (arr, coord, &node);
  return node ? node->ptr : 0;
}

void *vox_axis_add (vox_axis_array *arr, int coord, void *ptr)
{
  vox_axis_node *node = 0;
  unsigned int idx = vox_axis_array_find (arr, coord, &node);
  if (node)
    {
      void *oldptr = node->ptr;
      node->coord = coord;
      node->ptr   = ptr;
      return oldptr;
    }
  else
    vox_axis_array_insert_at (arr, idx, coord, ptr);

  return 0;
}

void *vox_axis_remove (vox_axis_array *arr, int coord)
{
  vox_axis_node *node = 0;
  unsigned int idx = vox_axis_array_find (arr, coord, &node);
  if (node)
    return vox_axis_array_remove_at (arr, idx);
  return 0;
}
