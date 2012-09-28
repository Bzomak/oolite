/*

Geometry.m

Oolite
Copyright (C) 2004-2012 Giles C Williams and contributors

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
MA 02110-1301, USA.

*/


/*
	PERFORMANCE NOTES
	
	This class has historically been noted for its significant presence in
	startup profiles, and is believed to be a major source of in-game stutter,
	so its performance characteristics are important.
	
	
	The following observations were made in r5352, starting up with no OXPs
	(except Debug.oxp) and no cache, and running through the complete set of
	demo ships.
	
	* In total, 379,344 geometries were allocated.
	* No more than 53 were allocated at a time.
	* 37.3% of them (141,585) never had a triangle added.
	* 51.2% had 4 or fewer triangles. 72.3% had 8 or fewer triangles. 93.3%
      had 16 or fewer triangles.
	* Triangle storage was reallocated 98,809 times.
	* More time was spent in ObjC memory management than C memory management.
	* In total, -addTriangle: was called 2,171,785 times.
	* Degenerate triangles come from input geometry, but don't seem to be
	  generated in inner nodes.
	
	Conclusions:
	* addTriangle: should be a static C function. The degenerate check is only
	  needed for input unless evidence to the contrary emerges.
	* Triangle storage should be lazily allocated.
	* Wasted space in triangle storage is unimportant with only 53 Geometries
	  live at a time, so the splitting code should use a pessimistic heuristic
	  for selecting the capacity of sub-geometries.
	* A pool allocator for Geometries should be helpful.
	* It may be worth putting space for some number of triangles in the
	  Geometry itself (conceptually similar to the standard short string
	  optimization).
	
	All but the last of these is implemented in r5353.
*/


#import "Geometry.h"

#import "OOMaths.h"
#import "Octree.h"
#import "OOLogging.h"


// MARK: GeometryData operations.

typedef struct OOGeometryInternalData GeometryData;

OOINLINE GeometryData MakeGeometryData(uint_fast32_t capacity);
OOINLINE void DestroyGeometryData(GeometryData *data);

OOINLINE void AddTriangle(GeometryData *data, Triangle tri);
static NO_INLINE_FUNC void AddTriangle_slow(GeometryData *data, Triangle tri);

#if PERFORM_CORNERS_WITHIN_GEOMETRY_TEST
static bool GeometryIsConvex(GeometryData *data);
static bool CornersAreWithinGeometry(GeometryData *data, OOScalar scale);
#endif

static OOScalar MaxDimensionFromOrigin(GeometryData *data);

void BuildSubOctree(GeometryData *data, OOOctreeBuilder *builder, OOScalar octreeRadius, NSUInteger depth);

static void SplitGeometryX(GeometryData *data, GeometryData *dPlus, GeometryData *dMinus, OOScalar x);
static void SplitGeometryY(GeometryData *data, GeometryData *dPlus, GeometryData *dMinus, OOScalar y);
static void SplitGeometryZ(GeometryData *data, GeometryData *dPlus, GeometryData *dMinus, OOScalar z);


// MARK: Inline function bodies.

OOINLINE GeometryData MakeGeometryData(uint_fast32_t capacity)
{
	NSCParameterAssert(capacity > 0);
	
	/*
		Returns a GeometryData with the specified pendingCapacity and all other
		fields 0. What we want is (Geometry){ .pendingCapacity = capacity }, but
		at least in current Apple-clang this doesn't work with the anonymous
		union.
		-- Ahruman 2012-09-27
	*/
	GeometryData result = { .capacity = 0 };
	result.pendingCapacity = capacity;
	return result;
}


OOINLINE void DestroyGeometryData(GeometryData *data)
{
	NSCParameterAssert(data != 0);
	
#if OO_DEBUG
	Triangle * const kScribbleValue = (Triangle *)-1L;
	NSCAssert(data->triangles != kScribbleValue, @"Attempt to destroy a GeometryData twice.");
#endif
	
	if (data->capacity != 0)
	{
		// If capacity is 0, triangles is actually pendingCapacity, so free() would be bad.
		free(data->triangles);
	}
	
#if OO_DEBUG
	data->triangles = kScribbleValue;
#endif
}


OOINLINE void AddTriangle(GeometryData *data, Triangle tri)
{
	NSCParameterAssert(data != NULL);
	
	if (data->count < data->capacity)
	{
		data->triangles[data->count++] = tri;
	}
	else
	{
		AddTriangle_slow(data, tri);
	}
}


@implementation Geometry

- (id) initWithCapacity:(NSUInteger)capacity
{
	NSParameterAssert(capacity > 0 && capacity < UINT32_MAX);
	
	if ((self = [super init]))
	{
		_data = MakeGeometryData((uint_fast32_t)capacity);
	}
	
	return self;
}


- (void) dealloc
{
	DestroyGeometryData(&_data);
	
	[super dealloc];
}


- (NSString *) descriptionComponents
{
#if PERFORM_CORNERS_WITHIN_GEOMETRY_TEST && !defined(NDEBUG)
	return [NSString stringWithFormat:@"%u triangles, %@", _data.count, GeometryIsConvex(&_data) ? @"convex" : @"not convex"];
#else
	return [NSString stringWithFormat:@"%u triangles", _data.count];
#endif
}


- (void) addTriangle:(Triangle)tri
{
	if (!OOTriangleIsDegenerate(tri))
	{
		AddTriangle(&_data, tri);
	}
}


#if PERFORM_CORNERS_WITHIN_GEOMETRY_TEST
static bool GeometryIsConvex(GeometryData *data)
{
	NSCParameterAssert(data != NULL);
	
	if (data->isKnownConvex)  return true;
	
	/*	Enumerate over triangles
		calculate normal for each one,
		then enumerate over vertices relative to a vertex on the triangle
		and check if they are on the forwardside or coplanar with the triangle.
		If a vertex is on the backside of any triangle then return NO.
	*/
	uint_fast32_t	i, j;
	for (i = 0; i < data->count; i++)
	{
		Vector v0 = data->triangles[i].v[0];
		Vector vn = calculateNormalForTriangle(&data->triangles[i]);
		
		for (j = 0; j < data->count; j++)
		{
			if (j != i)
			{
				if ((dot_product(vector_between(v0, data->triangles[j].v[0]), vn) < -0.001) ||
					(dot_product(vector_between(v0, data->triangles[j].v[1]), vn) < -0.001) ||
					(dot_product(vector_between(v0, data->triangles[j].v[2]), vn) < -0.001))	// within 1mm tolerance
				{
					return false;
				}
			}
		}
	}
	data->isKnownConvex = true;
	return true;
}


static bool CornersAreWithinGeometry(GeometryData *data, OOScalar scale)
{
	/*	enumerate over triangles
		calculate normal for each one,
		then enumerate over corners relative to a vertex on the triangle
		and check if they are on the forwardside or coplanar with the triangle.
		If a corner is on the backside of any triangle then return NO.
	*/
	uint_fast32_t		i;
	int_fast8_t			x, y, z;
	for (i = 0; i < data->count; i++)
	{
		Vector v0 = data->triangles[i].v[0];
		Vector vn = calculateNormalForTriangle(&data->triangles[i]);
		
		for (z = -1; z < 2; z += 2) for (y = -1; y < 2; y += 2) for (x = -1; x < 2; x += 2)
		{
			Vector vc = make_vector(scale * x, scale * y, scale * z);
			if (dot_product(vector_between(v0, vc), vn) < -0.001)
			{
				return NO;
			}
		}
	}
	return YES;
}
#endif


- (Octree *) findOctreeToDepth:(NSUInteger)depth
{
	OOOctreeBuilder *builder = [[[OOOctreeBuilder alloc] init] autorelease];
	OOScalar foundRadius = 0.5f + MaxDimensionFromOrigin(&_data);	// pad out from geometry by a half meter
	
	BuildSubOctree(&_data, builder, foundRadius, depth);
	
	return [builder buildOctreeWithRadius:foundRadius];
}

@end


static OOScalar MaxDimensionFromOrigin(GeometryData *data)
{
	NSCParameterAssert(data != NULL);
	
	// enumerate over triangles
	OOScalar		result = 0.0f;
	uint_fast32_t	i, j;
	for (i = 0; i < data->count; i++) for (j = 0; j < 3; j++)
	{
		Vector v = data->triangles[i].v[j];
		result = fmax(result, v.x);
		result = fmax(result, v.y);
		result = fmax(result, v.z);
	}
	return result;
}


void BuildSubOctree(GeometryData *data, OOOctreeBuilder *builder, OOScalar octreeRadius, NSUInteger depth)
{
	NSCParameterAssert(data != NULL && builder != nil);
	
	OOScalar offset = 0.5f * octreeRadius;
	
	if (data->count == 0)
	{
		// No geometry here.
		[builder writeEmpty];
		return;
	}
	
	if (octreeRadius <= OCTREE_MIN_RADIUS || depth <= 0)
	{
		// Maximum resolution reached and not full.
		[builder writeSolid];
		return;
	}
	
#if PERFORM_CORNERS_WITHIN_GEOMETRY_TEST
	if (GeometryIsConvex(data))	// we're convex!
	{
		if (CornersAreWithinGeometry(data, octreeRadius))	// all eight corners inside or on!
		{
			// FIXME: never reached?
			[builder writeSolid];
			return;
		}
	}
#endif

	/*
		As per performance notes, we want to use a heuristic which keeps the
		number of reallocations needed low with relatively little regard to
		allocation size.
		
		This table shows observed performance for several heuristics using
		vanilla Oolite r5352 (plus instrumentation). Values aren't precisely
		reproducible, but are reasonably stable.
		
		Heuristic: expression used to initialize subCapacity.
		
		PER: number of geometries per reallocation; in other words, a realloc
			 is needed one time per PER geometries.
		
		MEM: high water mark for total memory consumption (triangles arrays
			 only) across all live Geometries.
		
		Heuristic                   PER         MEM
		n_triangles                 3-4         71856
		n_triangles * 2             100         111384
		MAX(n_triangles * 2, 16)    300         111384
		MAX(n_triangles * 2, 21)    500         148512
		n_triangles * 3             500         165744
		MAX(n_triangles * 3, 16)    12000       165744
		MAX(n_triangles * 3, 21)    20000       165744
		
		The value 21 was chosen for reasons which, on reflection, were entirely
		wrong. Performance profiling shows no discernible difference between
		2,16 and 3,21.
	*/
	enum
	{
		kFactor = 2,
		kMinimum = 16
	};
	uint_fast32_t subCapacity = data->count * kFactor;
	if (subCapacity < kMinimum)  subCapacity = kMinimum;
	
	GeometryData g_000 = MakeGeometryData(subCapacity);
	GeometryData g_001 = MakeGeometryData(subCapacity);
	GeometryData g_010 = MakeGeometryData(subCapacity);
	GeometryData g_011 = MakeGeometryData(subCapacity);
	GeometryData g_100 = MakeGeometryData(subCapacity);
	GeometryData g_101 = MakeGeometryData(subCapacity);
	GeometryData g_110 = MakeGeometryData(subCapacity);
	GeometryData g_111 = MakeGeometryData(subCapacity);
	
	GeometryData g_xx1 = MakeGeometryData(subCapacity);
	GeometryData g_xx0 = MakeGeometryData(subCapacity);
	
	SplitGeometryZ(data, &g_xx1, &g_xx0, offset);
	if (g_xx0.count != 0)
	{
		GeometryData g_x00 = MakeGeometryData(subCapacity);
		GeometryData g_x10 = MakeGeometryData(subCapacity);
		
		SplitGeometryY(&g_xx0, &g_x10, &g_x00, offset);
		if (g_x00.count != 0)
		{
			SplitGeometryX(&g_x00, &g_100, &g_000, offset);
#if PERFORM_CORNERS_WITHIN_GEOMETRY_TEST
			g_000.isKnownConvex = data->isKnownConvex;
			g_100.isKnownConvex = data->isKnownConvex;
#endif
		}
		if (g_x10.count != 0)
		{
			SplitGeometryX(&g_x10, &g_110, &g_010, offset);
#if PERFORM_CORNERS_WITHIN_GEOMETRY_TEST
			g_010.isKnownConvex = data->isKnownConvex;
			g_110.isKnownConvex = data->isKnownConvex;
#endif
		}
		DestroyGeometryData(&g_x00);
		DestroyGeometryData(&g_x10);
	}
	if (g_xx1.count != 0)
	{
		GeometryData g_x01 = MakeGeometryData(subCapacity);
		GeometryData g_x11 = MakeGeometryData(subCapacity);
		
		SplitGeometryY(&g_xx1, &g_x11, &g_x01, offset);
		if (g_x01.count != 0)
		{
			SplitGeometryX(&g_x01, &g_101, &g_001, offset);
#if PERFORM_CORNERS_WITHIN_GEOMETRY_TEST
			g_001.isKnownConvex = data->isKnownConvex;
			g_101.isKnownConvex = data->isKnownConvex;
#endif
		}
		if (g_x11.count != 0)
		{
			SplitGeometryX(&g_x11, &g_111, &g_011, offset);
#if PERFORM_CORNERS_WITHIN_GEOMETRY_TEST
			g_011.isKnownConvex = data->isKnownConvex;
			g_111.isKnownConvex = data->isKnownConvex;
#endif
		}
		DestroyGeometryData(&g_x01);
		DestroyGeometryData(&g_x11);
	}
	DestroyGeometryData(&g_xx0);
	DestroyGeometryData(&g_xx1);
	
	[builder beginInnerNode];
	depth--;
	BuildSubOctree(&g_000, builder, offset, depth);
	BuildSubOctree(&g_001, builder, offset, depth);
	BuildSubOctree(&g_010, builder, offset, depth);
	BuildSubOctree(&g_011, builder, offset, depth);
	BuildSubOctree(&g_100, builder, offset, depth);
	BuildSubOctree(&g_101, builder, offset, depth);
	BuildSubOctree(&g_110, builder, offset, depth);
	BuildSubOctree(&g_111, builder, offset, depth);
	[builder endInnerNode];
	
	DestroyGeometryData(&g_000);
	DestroyGeometryData(&g_001);
	DestroyGeometryData(&g_010);
	DestroyGeometryData(&g_011);
	DestroyGeometryData(&g_100);
	DestroyGeometryData(&g_101);
	DestroyGeometryData(&g_110);
	DestroyGeometryData(&g_111);
}


static void TranslateGeometryX(GeometryData *data, OOScalar offset)
{
	NSCParameterAssert(data != NULL);
	
	// Optimization note: offset is never zero, so no early return.
	
	uint_fast32_t i, count = data->count;
	for (i = 0; i < count; i++)
	{
		data->triangles[i].v[0].x += offset;
		data->triangles[i].v[1].x += offset;
		data->triangles[i].v[2].x += offset;
	}
}


static void TranslateGeometryY(GeometryData *data, OOScalar offset)
{
	NSCParameterAssert(data != NULL);
	
	// Optimization note: offset is never zero, so no early return.
	
	uint_fast32_t i, count = data->count;
	for (i = 0; i < count; i++)
	{
		data->triangles[i].v[0].y += offset;
		data->triangles[i].v[1].y += offset;
		data->triangles[i].v[2].y += offset;
	}
}


static void TranslateGeometryZ(GeometryData *data, OOScalar offset)
{
	NSCParameterAssert(data != NULL);
	
	// Optimization note: offset is never zero, so no early return.
	
	uint_fast32_t i, count = data->count;
	for (i = 0; i < count; i++)
	{
		data->triangles[i].v[0].z += offset;
		data->triangles[i].v[1].z += offset;
		data->triangles[i].v[2].z += offset;
	}
}


static void SplitGeometryX(GeometryData *data, GeometryData *dPlus, GeometryData *dMinus, OOScalar x)
{
	// test each triangle splitting against x == 0.0
	uint_fast32_t	i, count = data->count;
	for (i = 0; i < count; i++)
	{
		bool done_tri = false;
		Vector v0 = data->triangles[i].v[0];
		Vector v1 = data->triangles[i].v[1];
		Vector v2 = data->triangles[i].v[2];
		
		if (v0.x >= 0.0f && v1.x >= 0.0f && v2.x >= 0.0f)
		{
			AddTriangle(dPlus, data->triangles[i]);
			done_tri = true;
		}
		else if (v0.x <= 0.0f && v1.x <= 0.0f && v2.x <= 0.0f)
		{
			AddTriangle(dMinus, data->triangles[i]);
			done_tri = true;
		}
		if (!done_tri)	// triangle must cross x == 0.0
		{
			OOScalar i01, i12, i20;
			if (v0.x == v1.x)
				i01 = -1.0f;
			else
				i01 = v0.x / (v0.x - v1.x);
			if (v1.x == v2.x)
				i12 = -1.0f;
			else
				i12 = v1.x / (v1.x - v2.x);
			if (v2.x == v0.x)
				i20 = -1.0f;
			else
				i20 = v2.x / (v2.x - v0.x);
			
			Vector v01 = make_vector(0.0f, i01 * (v1.y - v0.y) + v0.y, i01 * (v1.z - v0.z) + v0.z);
			Vector v12 = make_vector(0.0f, i12 * (v2.y - v1.y) + v1.y, i12 * (v2.z - v1.z) + v1.z);
			Vector v20 = make_vector(0.0f, i20 * (v0.y - v2.y) + v2.y, i20 * (v0.z - v2.z) + v2.z);
		
			// cases where a vertex is on the split.
			if (v0.x == 0.0f)
			{
				if (v1.x > 0)
				{
					AddTriangle(dPlus, make_triangle(v0, v1, v12));
					AddTriangle(dMinus, make_triangle(v0, v12, v2));
				}
				else
				{
					AddTriangle(dMinus, make_triangle(v0, v1, v12));
					AddTriangle(dPlus, make_triangle(v0, v12, v2));
				}
			}
			if (v1.x == 0.0f)
			{
				if (v2.x > 0)
				{
					AddTriangle(dPlus, make_triangle(v1, v2, v20));
					AddTriangle(dMinus, make_triangle(v1, v20, v0));
				}
				else
				{
					AddTriangle(dMinus, make_triangle(v1, v2, v20));
					AddTriangle(dPlus, make_triangle(v1, v20, v0));
				}
			}
			if (v2.x == 0.0f)
			{
				if (v0.x > 0)
				{
					AddTriangle(dPlus, make_triangle(v2, v0, v01));
					AddTriangle(dMinus, make_triangle(v2, v01, v1));
				}
				else
				{
					AddTriangle(dMinus, make_triangle(v2, v0, v01));
					AddTriangle(dPlus, make_triangle(v2, v01, v1));
				}
			}
			
			if (v0.x > 0.0f && v1.x > 0.0f && v2.x < 0.0f)
			{
				AddTriangle(dPlus, make_triangle(v0, v12, v20));
				AddTriangle(dPlus, make_triangle(v0, v1, v12));
				AddTriangle(dMinus, make_triangle(v20, v12, v2));
			}
			
			if (v0.x > 0.0f && v1.x < 0.0f && v2.x > 0.0f)
			{
				AddTriangle(dPlus, make_triangle(v2, v01, v12));
				AddTriangle(dPlus, make_triangle(v2, v0, v01));
				AddTriangle(dMinus, make_triangle(v12, v01, v1));
			}
			
			if (v0.x > 0.0f && v1.x < 0.0f && v2.x < 0.0f)
			{
				AddTriangle(dPlus, make_triangle(v20, v0, v01));
				AddTriangle(dMinus, make_triangle(v2, v20, v1));
				AddTriangle(dMinus, make_triangle(v20, v01, v1));
			}
			
			if (v0.x < 0.0f && v1.x > 0.0f && v2.x > 0.0f)
			{
				AddTriangle(dMinus, make_triangle(v01, v20, v0));
				AddTriangle(dPlus, make_triangle(v1, v20, v01));
				AddTriangle(dPlus, make_triangle(v1, v2, v20));
			}
			
			if (v0.x < 0.0f && v1.x > 0.0f && v2.x < 0.0f)
			{
				AddTriangle(dPlus, make_triangle(v01, v1, v12));
				AddTriangle(dMinus, make_triangle(v0, v01, v2));
				AddTriangle(dMinus, make_triangle(v01, v12, v2));
			}
			
			if (v0.x < 0.0f && v1.x < 0.0f && v2.x > 0.0f)
			{
				AddTriangle(dPlus, make_triangle(v12, v2, v20));
				AddTriangle(dMinus, make_triangle(v1, v12, v0));
				AddTriangle(dMinus, make_triangle(v12, v20, v0));
			}			

		}
	}
	TranslateGeometryX(dPlus, -x);
	TranslateGeometryX(dMinus, x);
}


static void SplitGeometryY(GeometryData *data, GeometryData *dPlus, GeometryData *dMinus, OOScalar y)
{
	// test each triangle splitting against y == 0.0
	uint_fast32_t	i, count = data->count;
	for (i = 0; i < count; i++)
	{
		bool done_tri = false;
		Vector v0 = data->triangles[i].v[0];
		Vector v1 = data->triangles[i].v[1];
		Vector v2 = data->triangles[i].v[2];

		if (v0.y >= 0.0f && v1.y >= 0.0f && v2.y >= 0.0f)
		{
			AddTriangle(dPlus, data->triangles[i]);
			done_tri = true;
		}
		if (v0.y <= 0.0f && v1.y <= 0.0f && v2.y <= 0.0f)
		{
			AddTriangle(dMinus, data->triangles[i]);
			done_tri = true;
		}
		if (!done_tri)	// triangle must cross y == 0.0
		{
			OOScalar i01, i12, i20;
			
			if (v0.y == v1.y)
				i01 = -1.0f;
			else
				i01 = v0.y / (v0.y - v1.y);
			if (v1.y == v2.y)
				i12 = -1.0f;
			else
				i12 = v1.y / (v1.y - v2.y);
			if (v2.y == v0.y)
				i20 = -1.0f;
			else
				i20 = v2.y / (v2.y - v0.y);
			
			Vector v01 = make_vector(i01 * (v1.x - v0.x) + v0.x, 0.0f, i01 * (v1.z - v0.z) + v0.z);
			Vector v12 = make_vector(i12 * (v2.x - v1.x) + v1.x, 0.0f, i12 * (v2.z - v1.z) + v1.z);
			Vector v20 = make_vector(i20 * (v0.x - v2.x) + v2.x, 0.0f, i20 * (v0.z - v2.z) + v2.z);
			
			// cases where a vertex is on the split.
			if (v0.y == 0.0f)
			{
				if (v1.y > 0)
				{
					AddTriangle(dPlus, make_triangle(v0, v1, v12));
					AddTriangle(dMinus, make_triangle(v0, v12, v2));
				}
				else
				{
					AddTriangle(dMinus, make_triangle(v0, v1, v12));
					AddTriangle(dPlus, make_triangle(v0, v12, v2));
				}
			}
			if (v1.y == 0.0f)
			{
				if (v2.y > 0)
				{
					AddTriangle(dPlus, make_triangle(v1, v2, v20));
					AddTriangle(dMinus, make_triangle(v1, v20, v0));
				}
				else
				{
					AddTriangle(dMinus, make_triangle(v1, v2, v20));
					AddTriangle(dPlus, make_triangle(v1, v20, v0));
				}
			}
			if (v2.y == 0.0f)
			{
				if (v0.y > 0)
				{
					AddTriangle(dPlus, make_triangle(v2, v0, v01));
					AddTriangle(dMinus, make_triangle(v2, v01, v1));
				}
				else
				{
					AddTriangle(dMinus, make_triangle(v2, v0, v01));
					AddTriangle(dPlus, make_triangle(v2, v01, v1));
				}
			}
			
			if (v0.y > 0.0f && v1.y > 0.0f && v2.y < 0.0f)
			{
				AddTriangle(dPlus, make_triangle(v0, v12, v20));
				AddTriangle(dPlus, make_triangle(v0, v1, v12));
				AddTriangle(dMinus, make_triangle(v20, v12, v2));
			}
			
			if (v0.y > 0.0f && v1.y < 0.0f && v2.y > 0.0f)
			{
				AddTriangle(dPlus, make_triangle(v2, v01, v12));
				AddTriangle(dPlus, make_triangle(v2, v0, v01));
				AddTriangle(dMinus, make_triangle(v12, v01, v1));
			}
			
			if (v0.y > 0.0f && v1.y < 0.0f && v2.y < 0.0f)
			{
				AddTriangle(dPlus, make_triangle(v20, v0, v01));
				AddTriangle(dMinus, make_triangle(v2, v20, v1));
				AddTriangle(dMinus, make_triangle(v20, v01, v1));
			}
			
			if (v0.y < 0.0f && v1.y > 0.0f && v2.y > 0.0f)
			{
				AddTriangle(dMinus, make_triangle(v01, v20, v0));
				AddTriangle(dPlus, make_triangle(v1, v20, v01));
				AddTriangle(dPlus, make_triangle(v1, v2, v20));
			}
			
			if (v0.y < 0.0f && v1.y > 0.0f && v2.y < 0.0f)
			{
				AddTriangle(dPlus, make_triangle(v01, v1, v12));
				AddTriangle(dMinus, make_triangle(v0, v01, v2));
				AddTriangle(dMinus, make_triangle(v01, v12, v2));
			}
			
			if (v0.y < 0.0f && v1.y < 0.0f && v2.y > 0.0f)
			{
				AddTriangle(dPlus, make_triangle(v12, v2, v20));
				AddTriangle(dMinus, make_triangle(v1, v12, v0));
				AddTriangle(dMinus, make_triangle(v12, v20, v0));
			}			
		}
	}
	TranslateGeometryY(dPlus, -y);
	TranslateGeometryY(dMinus, y);
}


static void SplitGeometryZ(GeometryData *data, GeometryData *dPlus, GeometryData *dMinus, OOScalar z)
{
	// test each triangle splitting against z == 0.0
	uint_fast32_t	i, count = data->count;
	for (i = 0; i < count; i++)
	{
		bool done_tri = false;
		Vector v0 = data->triangles[i].v[0];
		Vector v1 = data->triangles[i].v[1];
		Vector v2 = data->triangles[i].v[2];
		
		if (v0.z >= 0.0f && v1.z >= 0.0f && v2.z >= 0.0f)
		{
			AddTriangle(dPlus, data->triangles[i]);
			done_tri = true;
		}
		else if (v0.z <= 0.0f && v1.z <= 0.0f && v2.z <= 0.0f)
		{
			AddTriangle(dMinus, data->triangles[i]);
			done_tri = true;
		}
		if (!done_tri)	// triangle must cross z == 0.0
		{
			OOScalar i01, i12, i20;
			
			if (v0.z == v1.z)
				i01 = -1.0f;
			else
				i01 = v0.z / (v0.z - v1.z);
			if (v1.z == v2.z)
				i12 = -1.0f;
			else
				i12 = v1.z / (v1.z - v2.z);
			if (v2.z == v0.z)
				i20 = -1.0f;
			else
				i20 = v2.z / (v2.z - v0.z);
			
			Vector v01 = make_vector(i01 * (v1.x - v0.x) + v0.x, i01 * (v1.y - v0.y) + v0.y, 0.0f);
			Vector v12 = make_vector(i12 * (v2.x - v1.x) + v1.x, i12 * (v2.y - v1.y) + v1.y, 0.0f);
			Vector v20 = make_vector(i20 * (v0.x - v2.x) + v2.x, i20 * (v0.y - v2.y) + v2.y, 0.0f);
		
			// cases where a vertex is on the split.
			if (v0.z == 0.0f)
			{
				if (v1.z > 0)
				{
					AddTriangle(dPlus, make_triangle(v0, v1, v12));
					AddTriangle(dMinus, make_triangle(v0, v12, v2));
				}
				else
				{
					AddTriangle(dMinus, make_triangle(v0, v1, v12));
					AddTriangle(dPlus, make_triangle(v0, v12, v2));
				}
			}
			if (v1.z == 0.0f)
			{
				if (v2.z > 0)
				{
					AddTriangle(dPlus, make_triangle(v1, v2, v20));
					AddTriangle(dMinus, make_triangle(v1, v20, v0));
				}
				else
				{
					AddTriangle(dMinus, make_triangle(v1, v2, v20));
					AddTriangle(dPlus, make_triangle(v1, v20, v0));
				}
			}
			if (v2.z == 0.0f)
			{
				if (v0.z > 0)
				{
					AddTriangle(dPlus, make_triangle(v2, v0, v01));
					AddTriangle(dMinus, make_triangle(v2, v01, v1));
				}
				else
				{
					AddTriangle(dMinus, make_triangle(v2, v0, v01));
					AddTriangle(dPlus, make_triangle(v2, v01, v1));
				}
			}
			
			if (v0.z > 0.0f && v1.z > 0.0f && v2.z < 0.0f)
			{
				AddTriangle(dPlus, make_triangle(v0, v12, v20));
				AddTriangle(dPlus, make_triangle(v0, v1, v12));
				AddTriangle(dMinus, make_triangle(v20, v12, v2));
			}
			
			if (v0.z > 0.0f && v1.z < 0.0f && v2.z > 0.0f)
			{
				AddTriangle(dPlus, make_triangle(v2, v01, v12));
				AddTriangle(dPlus, make_triangle(v2, v0, v01));
				AddTriangle(dMinus, make_triangle(v12, v01, v1));
			}
			
			if (v0.z > 0.0f && v1.z < 0.0f && v2.z < 0.0f)
			{
				AddTriangle(dPlus, make_triangle(v20, v0, v01));
				AddTriangle(dMinus, make_triangle(v2, v20, v1));
				AddTriangle(dMinus, make_triangle(v20, v01, v1));
			}
			
			if (v0.z < 0.0f && v1.z > 0.0f && v2.z > 0.0f)
			{
				AddTriangle(dMinus, make_triangle(v01, v20, v0));
				AddTriangle(dPlus, make_triangle(v1, v20, v01));
				AddTriangle(dPlus, make_triangle(v1, v2, v20));
			}
			
			if (v0.z < 0.0f && v1.z > 0.0f && v2.z < 0.0f)
			{
				AddTriangle(dPlus, make_triangle(v01, v1, v12));
				AddTriangle(dMinus, make_triangle(v0, v01, v2));
				AddTriangle(dMinus, make_triangle(v01, v12, v2));
			}
			
			if (v0.z < 0.0f && v1.z < 0.0f && v2.z > 0.0f)
			{
				AddTriangle(dPlus, make_triangle(v12, v2, v20));
				AddTriangle(dMinus, make_triangle(v1, v12, v0));
				AddTriangle(dMinus, make_triangle(v12, v20, v0));
			}			

		}
	}
	TranslateGeometryZ(dPlus, -z);
	TranslateGeometryZ(dMinus, z);
}


/*
	void AddTriangle_slow(GeometryData *data, Triangle tri)
	
	Slow path for AddTriangle(). Ensure that there is enough space to add a
	triangle, then actually add it.
	
	If no memory has been allocated yet, capacity is 0 and pendingCapacity is
	the capacity passed to MakeGeometryData(). Otherwise, capacity > 0 and
	triangles is a valid pointer.
	
	This is marked noinline so that the fast path in AddTriange() can be
	inlined. Without the attribute, clang (and probably gcc too) will inline
	AddTriangles_slow() into AddTriangle() (because it only has one call site),
	making AddTriangle() to heavy to inline.
*/
static NO_INLINE_FUNC void AddTriangle_slow(GeometryData *data, Triangle tri)
{
	NSCParameterAssert(data->count == data->capacity);
	
	if (data->capacity == 0)
	{
		/*
			Lazily allocate triangle storage, since a significant portion of
			Geometries never have any triangles added to them. Note that
			max_triangles is set to the specified capacity in init even though
			the actual capacity is zero at that point.
		*/
		NSCAssert(data->pendingCapacity > 0, @"GeometryData has zero pendingCapacity.");
		
		data->capacity = (uint_fast32_t)data->pendingCapacity;
		data->triangles = malloc(data->capacity * sizeof(Triangle));
	}
	else
	{
		// create more space by doubling the capacity of this geometry.
		data->capacity = 1 + data->capacity * 2;
		data->triangles = realloc(data->triangles, data->capacity * sizeof(Triangle));
		
		// N.b.: we leak here if realloc() failed, but we're about to abort anyway.
	}
	
	if (EXPECT_NOT(data->triangles == NULL))
	{
		OOLog(kOOLogAllocationFailure, @"!!!!! Ran out of memory to allocate more geometry!");
		exit(EXIT_FAILURE);
	}
	
	data->triangles[data->count++] = tri;
}
