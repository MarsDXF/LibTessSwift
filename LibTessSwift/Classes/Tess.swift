//
//  Tess.swift
//  Squishy2048
//
//  Created by Luiz Fernando Silva on 26/02/17.
//  Copyright © 2017 Luiz Fernando Silva. All rights reserved.
//

public enum WindingRule: String {
    case evenOdd
    case nonZero
    case positive
    case negative
    case absGeqTwo
}

public enum ElementType {
    case polygons
    case connectedPolygons
    case boundaryContours
}

public enum ContourOrientation {
    case original
    case clockwise
    case counterClockwise
}

public struct ContourVertex: CustomStringConvertible {
    public var Position: Vec3
    public var Data: Any?
    
    public init() {
        Position = .Zero
        Data = nil
    }
    
    public init(Position: Vec3) {
        self.Position = Position
        self.Data = nil
    }
    
    public init(Position: Vec3, Data: Any?) {
        self.Position = Position
        self.Data = Data
    }
    
    public var description: String {
        return "\(Position), \(Data)"
    }
}

public typealias CombineCallback = (_ position: Vec3, _ data: [Any?], _ weights: [CGFloat]) -> Any?

public class Tess {
    internal var _mesh: Mesh!
    internal var _normal: Vec3
    internal var _sUnit: Vec3 = .Zero
    internal var _tUnit: Vec3 = .Zero

    internal var _bminX: CGFloat
    internal var _bminY: CGFloat
    internal var _bmaxX: CGFloat
    internal var _bmaxY: CGFloat

    internal var _windingRule: WindingRule

    internal var _dict: Dict<ActiveRegion>!
    internal var _pq: PriorityQueue<MeshUtils.Vertex>!
    internal var _event: MeshUtils.Vertex!

    internal var _combineCallback: CombineCallback?

    internal var _vertices: [ContourVertex]!
    internal var _vertexCount: Int
    internal var _elements: [Int]!
    internal var _elementCount: Int

    public var Normal: Vec3 { get { return _normal } set { _normal = newValue } }

    public var SUnitX: CGFloat = 1
    public var SUnitY: CGFloat = 0
#if DOUBLE
    public var SentinelCoord: CGFloat = 4e150
#else
    public var SentinelCoord: CGFloat = 4e30
#endif

    /// <summary>
    /// If true, will remove empty (zero area) polygons.
    /// </summary>
    public var NoEmptyPolygons = false

    /// <summary>
    /// If true, will use pooling to reduce GC (compare performance with/without, can vary wildly).
    /// </summary>
    public var UsePooling = false

    public var Vertices: [ContourVertex]! { get { return _vertices } }
    public var VertexCount: Int { get { return _vertexCount } }

    public var Elements: [Int]! { get { return _elements } }
    public var ElementCount: Int { get { return _elementCount } }

    public init() {
        _normal = Vec3.Zero
        _bminX = 0
        _bminY = 0
        _bmaxX = 0
        _bmaxY = 0

        _windingRule = WindingRule.evenOdd
        _mesh = nil
        
        _vertices = nil
        _vertexCount = 0
        _elements = nil
        _elementCount = 0
    }
    
    private func ComputeNormal(norm: inout Vec3) {
        var v = _mesh!._vHead._next!

        var minVal: [CGFloat] = [ v._coords.X, v._coords.Y, v._coords.Z ]
        var minVert: ContiguousArray<MeshUtils.Vertex> = [ v, v, v ]
        var maxVal: [CGFloat] = [ v._coords.X, v._coords.Y, v._coords.Z ]
        var maxVert: ContiguousArray<MeshUtils.Vertex> = [ v, v, v ]
        
        func subMinMax(_ index: Int) -> CGFloat {
            return maxVal[index] - minVal[index]
        }
        
        while v !== _mesh!._vHead {
            
            if (v._coords.X < minVal[0]) {
                minVal[0] = v._coords.X
                minVert[0] = v
            }
            if (v._coords.Y < minVal[1]) {
                minVal[1] = v._coords.Y
                minVert[1] = v
            }
            if (v._coords.Z < minVal[2]) {
                minVal[2] = v._coords.Z
                minVert[2] = v }
            
            if (v._coords.X > maxVal[0]) {
                maxVal[0] = v._coords.X
                maxVert[0] = v
            }
            if (v._coords.Y > maxVal[1]) {
                maxVal[1] = v._coords.Y
                maxVert[1] = v
            }
            if (v._coords.Z > maxVal[2]) {
                maxVal[2] = v._coords.Z
                maxVert[2] = v
            }
            
            v = v._next!
        }
        
        // Find two vertices separated by at least 1/sqrt(3) of the maximum
        // distance between any two vertices
        var i = 0
        //if (maxVal[1] - minVal[1] > maxVal[0] - minVal[0]) {
        if subMinMax(1) > subMinMax(0) {
            i = 1
        }
        
        //if (maxVal[2] - minVal[2] > maxVal[i] - minVal[i]) {
        if subMinMax(2) > subMinMax(i) {
            i = 2
        }
        
        if (minVal[i] >= maxVal[i]) {
            // All vertices are the same -- normal doesn't matter
            norm = Vec3(X: 0, Y: 0, Z: 1)
            return
        }
        
        // Look for a third vertex which forms the triangle with maximum area
        // (Length of normal == twice the triangle area)
        var maxLen2: CGFloat = 0
        var tLen2: CGFloat
        let v1 = minVert[i]
        let v2 = maxVert[i]
        var d1: Vec3 = .Zero, d2: Vec3 = .Zero, tNorm: Vec3 = .Zero
        Vec3.Sub(lhs: &v1._coords, rhs: &v2._coords, result: &d1)
        
        v = _mesh!._vHead._next!
        
        while v !== _mesh!._vHead {
            defer {
                v = v._next!
            }
            
            Vec3.Sub(lhs: &v._coords, rhs: &v2._coords, result: &d2)
            tNorm.X = d1.Y * d2.Z - d1.Z * d2.Y
            tNorm.Y = d1.Z * d2.X - d1.X * d2.Z
            tNorm.Z = d1.X * d2.Y - d1.Y * d2.X
            tLen2 = tNorm.X * tNorm.X + tNorm.Y * tNorm.Y + tNorm.Z * tNorm.Z
            
            if (tLen2 > maxLen2) {
                maxLen2 = tLen2
                norm = tNorm
            }
        }

        if (maxLen2 <= 0.0) {
            // All points lie on a single line -- any decent normal will do
            norm = Vec3.Zero
            i = Vec3.LongAxis(v: &d1)
            norm[i] = 1
        }
    }

    private func CheckOrientation() {
        // When we compute the normal automatically, we choose the orientation
        // so that the the sum of the signed areas of all contours is non-negative.
        var area: CGFloat = 0.0
        
        var f = _mesh!._fHead._next!
        
        while f !== _mesh!._fHead {
            defer {
                f = f._next!
            }
            
            if (f._anEdge!._winding <= 0) {
                continue
            }
            area += MeshUtils.FaceArea(f)
        }
        
        if (area < 0.0) {
            // Reverse the orientation by flipping all the t-coordinates
            _mesh._vHead.loop {
                $0._t = -$0._t
            }
            
            Vec3.Neg(v: &_tUnit)
        }
    }

    private func ProjectPolygon() {
        var norm = _normal

        var computedNormal = false
        if (norm.X == 0.0 && norm.Y == 0.0 && norm.Z == 0.0) {
            ComputeNormal(norm: &norm)
            _normal = norm
            computedNormal = true
        }

        let i = Vec3.LongAxis(v: &norm)
        
        _sUnit[i] = 0
        _sUnit[(i + 1) % 3] = SUnitX
        _sUnit[(i + 2) % 3] = SUnitY

        _tUnit[i] = 0
        _tUnit[(i + 1) % 3] = norm[i] > 0.0 ? -SUnitY : SUnitY
        _tUnit[(i + 2) % 3] = norm[i] > 0.0 ? SUnitX : -SUnitX

        // Project the vertices onto the sweep plane
        _mesh._vHead.loop { v in
            Vec3.Dot(u: &v._coords, v: &_sUnit, dot: &v._s)
            Vec3.Dot(u: &v._coords, v: &_tUnit, dot: &v._t)
        }
        
        if (computedNormal) {
            CheckOrientation()
        }

        // Compute ST bounds.
        var first = true
        
        _mesh._vHead.loop { v in
            if (first) {
                _bmaxX = v._s
                _bminX = v._s
                
                _bmaxY = v._t
                _bminY = v._t
                first = false
            } else {
                if (v._s < _bminX) { _bminX = v._s }
                if (v._s > _bmaxX) { _bmaxX = v._s }
                if (v._t < _bminY) { _bminY = v._t }
                if (v._t > _bmaxY) { _bmaxY = v._t }
            }
        }
    }

    /// <summary>
    /// TessellateMonoRegion( face ) tessellates a monotone region
    /// (what else would it do??)  The region must consist of a single
    /// loop of half-edges (see mesh.h) oriented CCW.  "Monotone" in this
    /// case means that any vertical line intersects the interior of the
    /// region in a single interval.  
    /// 
    /// Tessellation consists of adding interior edges (actually pairs of
    /// half-edges), to split the region into non-overlapping triangles.
    /// 
    /// The basic idea is explained in Preparata and Shamos (which I don't
    /// have handy right now), although their implementation is more
    /// complicated than this one.  The are two edge chains, an upper chain
    /// and a lower chain.  We process all vertices from both chains in order,
    /// from right to left.
    /// 
    /// The algorithm ensures that the following invariant holds after each
    /// vertex is processed: the untessellated region consists of two
    /// chains, where one chain (say the upper) is a single edge, and
    /// the other chain is concave.  The left vertex of the single edge
    /// is always to the left of all vertices in the concave chain.
    /// 
    /// Each step consists of adding the rightmost unprocessed vertex to one
    /// of the two chains, and forming a fan of triangles from the rightmost
    /// of two chain endpoints.  Determining whether we can add each triangle
    /// to the fan is a simple orientation test.  By making the fan as large
    /// as possible, we restore the invariant (check it yourself).
    /// </summary>
    private func TessellateMonoRegion(_ face: MeshUtils.Face) {
        // All edges are oriented CCW around the boundary of the region.
        // First, find the half-edge whose origin vertex is rightmost.
        // Since the sweep goes from left to right, face->anEdge should
        // be close to the edge we want.
        var up = face._anEdge!
        assert(up._Lnext !== up && up._Lnext?._Lnext !== up)
        
        while (Geom.VertLeq(up._Dst!, up._Org!)) { up = up._Lprev! }
        while (Geom.VertLeq(up._Org!, up._Dst!)) { up = up._Lnext! }
        
        var lo = up._Lprev!
        
        while (up._Lnext !== lo) {
            if (Geom.VertLeq(up._Dst, lo._Org)) {
                // up.Dst is on the left. It is safe to form triangles from lo.Org.
                // The EdgeGoesLeft test guarantees progress even when some triangles
                // are CW, given that the upper and lower chains are truly monotone.
                while (lo._Lnext !== up && (Geom.EdgeGoesLeft(lo._Lnext)
                    || Geom.EdgeSign(lo._Org, lo._Dst, lo._Lnext._Dst) <= 0.0)) {
                    lo = _mesh.Connect(lo._Lnext, lo)._Sym
                }
                lo = lo._Lprev
            } else {
                // lo.Org is on the left.  We can make CCW triangles from up.Dst.
                while (lo._Lnext !== up && (Geom.EdgeGoesRight(up._Lprev)
                    || Geom.EdgeSign(up._Dst, up._Org, up._Lprev._Org) >= 0.0)) {
                    up = _mesh.Connect(up, up._Lprev)._Sym
                }
                up = up._Lnext
            }
        }
        
        // Now lo.Org == up.Dst == the leftmost vertex.  The remaining region
        // can be tessellated in a fan from this leftmost vertex.
        assert(lo._Lnext !== up)
        while (lo._Lnext._Lnext !== up) {
            lo = _mesh.Connect(lo._Lnext, lo)._Sym
        }
    }

    /// <summary>
    /// TessellateInterior( mesh ) tessellates each region of
    /// the mesh which is marked "inside" the polygon. Each such region
    /// must be monotone.
    /// </summary>
    private func TessellateInterior() {
        _mesh.forEachFace { f in
            if (f._inside) {
                TessellateMonoRegion(f)
            }
        }
    }

    /// <summary>
    /// DiscardExterior zaps (ie. sets to nil) all faces
    /// which are not marked "inside" the polygon.  Since further mesh operations
    /// on nil faces are not allowed, the main purpose is to clean up the
    /// mesh so that exterior loops are not represented in the data structure.
    /// </summary>
    private func DiscardExterior() {
        _mesh.forEachFace { f in
            if(!f._inside) {
                _mesh.ZapFace(f)
            }
        }
    }

    /// <summary>
    /// SetWindingNumber( value, keepOnlyBoundary ) resets the
    /// winding numbers on all edges so that regions marked "inside" the
    /// polygon have a winding number of "value", and regions outside
    /// have a winding number of 0.
    /// 
    /// If keepOnlyBoundary is TRUE, it also deletes all edges which do not
    /// separate an interior region from an exterior one.
    /// </summary>
    private func SetWindingNumber(_ value: Int, _ keepOnlyBoundary: Bool) {
        
        var eNext: MeshUtils.Edge
        
        var e = _mesh._eHead._next!
        while e !== _mesh._eHead {
            defer {
                e = eNext
            }
            
            eNext = e._next
            if (e._Rface._inside != e._Lface._inside) {

                /* This is a boundary edge (one side is interior, one is exterior). */
                e._winding = (e._Lface._inside) ? value : -value
            } else {

                /* Both regions are interior, or both are exterior. */
                if (!keepOnlyBoundary) {
                    e._winding = 0
                } else {
                    _mesh.Delete(e)
                }
            }
        }
    }

    private func GetNeighbourFace(_ edge: MeshUtils.Edge) -> Int {
        if (edge._Rface == nil) {
            return MeshUtils.Undef
        }
        if (!edge._Rface!._inside) {
            return MeshUtils.Undef
        }
        return edge._Rface!._n
    }

    private func OutputPolymesh(_ elementType: ElementType, _ polySize: Int) {
        var v: MeshUtils.Vertex
        var f: MeshUtils.Face
        var edge: MeshUtils.Edge
        var maxFaceCount = 0
        var maxVertexCount = 0
        var faceVerts: Int = 0, i: Int = 0
        var polySize = polySize

        if (polySize < 3) {
            polySize = 3
        }
        // Assume that the input data is triangles now.
        // Try to merge as many polygons as possible
        if (polySize > 3) {
            _mesh.MergeConvexFaces(maxVertsPerFace: polySize)
        }

        // Mark unused
        v = _mesh._vHead._next
        
        while v !== _mesh._vHead {
            v._n = MeshUtils.Undef
            v = v._next
        }

        // Create unique IDs for all vertices and faces.
        f = _mesh._fHead._next
        
        while f !== _mesh._fHead {
            defer {
                f = f._next
            }
            
            f._n = MeshUtils.Undef
            if (!f._inside) { continue }

            if (NoEmptyPolygons) {
                var area = MeshUtils.FaceArea(f)
                if (abs(area) < CGFloat.leastNonzeroMagnitude) {
                    continue
                }
            }

            edge = f._anEdge!
            faceVerts = 0
            repeat {
                v = edge._Org
                if (v._n == MeshUtils.Undef) {
                    v._n = maxVertexCount
                    maxVertexCount += 1
                }
                faceVerts += 1
                edge = edge._Lnext
            }
            while (edge !== f._anEdge)

            assert(faceVerts <= polySize)

            f._n = maxFaceCount
            maxFaceCount += 1
        }

        _elementCount = maxFaceCount
        if (elementType == ElementType.connectedPolygons) {
            maxFaceCount *= 2
        }
        _elements = Array(repeating: 0, count: maxFaceCount * polySize)

        _vertexCount = maxVertexCount
        _vertices = Array(repeating: ContourVertex(Position: .Zero, Data: nil), count: _vertexCount)

        // Output vertices.
        v = _mesh._vHead._next
        while v !== _mesh._vHead {
            defer {
                v = v._next
            }
            
            if (v._n != MeshUtils.Undef) {
                // Store coordinate
                _vertices[v._n].Position = v._coords
                _vertices[v._n].Data = v._data
            }
        }

        // Output indices.
        var elementIndex = 0
        f = _mesh._fHead._next
        while f !== _mesh._fHead {
            defer {
                f = f._next
            }
            
            if (!f._inside) { continue }

            if (NoEmptyPolygons) {
                let area = MeshUtils.FaceArea(f)
                if (abs(area) < CGFloat.leastNonzeroMagnitude) {
                    continue
                }
            }

            // Store polygon
            edge = f._anEdge
            faceVerts = 0
            repeat {
                v = edge._Org
                _elements[elementIndex] = v._n
                elementIndex += 1
                faceVerts += 1
                edge = edge._Lnext
            } while (edge !== f._anEdge)
            // Fill unused.
            for _ in faceVerts..<polySize {
                _elements[elementIndex] = MeshUtils.Undef
                elementIndex += 1
            }

            // Store polygon connectivity
            if (elementType == ElementType.connectedPolygons) {
                edge = f._anEdge!
                repeat {
                    _elements[elementIndex] = GetNeighbourFace(edge)
                    elementIndex += 1
                    edge = edge._Lnext
                } while (edge !== f._anEdge)
                
                // Fill unused.
                for _ in faceVerts..<polySize {
                    _elements[elementIndex] = MeshUtils.Undef
                    elementIndex += 1
                }
            }
        }
    }

    private func OutputContours() {
        var startVert = 0
        var vertCount = 0

        _vertexCount = 0
        _elementCount = 0
        
        _mesh.forEachFace { f in
            if (!f._inside) {
                return
            }
            
            let start = f._anEdge!
            var edge = f._anEdge!
            repeat {
                _vertexCount += 1
                edge = edge._Lnext!
            } while (edge !== start)
            
            _elementCount += 1
        }

        _elements = Array(repeating: 0, count: _elementCount * 2)
        _vertices = Array(repeating: ContourVertex(Position: .Zero, Data: nil), count: _vertexCount)

        var vertIndex = 0
        var elementIndex = 0
        
        startVert = 0
        
        _mesh.forEachFace { f in
            if (!f._inside) {
                return
            }
            
            vertCount = 0
            let start = f._anEdge!
            var edge = f._anEdge!
            repeat {
                _vertices[vertIndex].Position = edge._Org._coords
                _vertices[vertIndex].Data = edge._Org._data
                vertIndex += 1
                vertCount += 1
                edge = edge._Lnext!
            } while (edge !== start)
            
            _elements[elementIndex] = startVert
            elementIndex += 1
            _elements[elementIndex] = vertCount
            elementIndex += 1
            
            startVert += vertCount
        }
    }

    private func SignedArea(_ vertices: [ContourVertex]) -> CGFloat {
        var area: CGFloat = 0.0
        
        for i in 0..<vertices.count {
            let v0 = vertices[i]
            let v1 = vertices[(i + 1) % vertices.count]

            area += v0.Position.X * v1.Position.Y
            area -= v0.Position.Y * v1.Position.X
        }

        return 0.5 * area
    }

    public func AddContour(_ vertices: [ContourVertex]) {
        AddContour(vertices, ContourOrientation.original)
    }

    public func AddContour(_ vertices: [ContourVertex], _ forceOrientation: ContourOrientation) {
        if (_mesh == nil) {
            _mesh = Mesh()
        }

        var reverse = false
        if (forceOrientation != ContourOrientation.original) {
            let area = SignedArea(vertices)
            reverse = (forceOrientation == ContourOrientation.clockwise && area < 0.0) || (forceOrientation == ContourOrientation.counterClockwise && area > 0.0)
        }

        var e: MeshUtils.Edge! = nil
        for i in 0..<vertices.count {
            if (e == nil) {
                e = _mesh.MakeEdge()
                _mesh.Splice(e, e._Sym)
            } else {
                // Create a new vertex and edge which immediately follow e
                // in the ordering around the left face.
                _=_mesh.SplitEdge(e)
                e = e._Lnext
            }
            
            let index = reverse ? vertices.count - 1 - i : i
            // The new vertex is now e._Org.
            e._Org._coords = vertices[index].Position
            e._Org._data = vertices[index].Data

            // The winding of an edge says how the winding number changes as we
            // cross from the edge's right face to its left face.  We add the
            // vertices in such an order that a CCW contour will add +1 to
            // the winding number of the region inside the contour.
            e._winding = 1
            e._Sym._winding = -1
        }
    }

    public func Tessellate(windingRule: WindingRule, elementType: ElementType, polySize: Int) {
        Tessellate(windingRule: windingRule, elementType: elementType, polySize: polySize, combineCallback: nil)
    }

    public func Tessellate(windingRule: WindingRule, elementType: ElementType, polySize: Int, combineCallback: CombineCallback?) {
        _normal = Vec3.Zero
        _vertices = nil
        _elements = nil

        _windingRule = windingRule
        _combineCallback = combineCallback

        if (_mesh == nil) {
            return
        }

        // Determine the polygon normal and project vertices onto the plane
        // of the polygon.
        ProjectPolygon()

        // ComputeInterior computes the planar arrangement specified
        // by the given contours, and further subdivides this arrangement
        // into regions.  Each region is marked "inside" if it belongs
        // to the polygon, according to the rule given by windingRule.
        // Each interior region is guaranteed be monotone.
        ComputeInterior()

        // If the user wants only the boundary contours, we throw away all edges
        // except those which separate the interior from the exterior.
        // Otherwise we tessellate all the regions marked "inside".
        if (elementType == ElementType.boundaryContours) {
            SetWindingNumber(1, true)
        } else {
            TessellateInterior()
        }

        _mesh!.Check()

        if (elementType == ElementType.boundaryContours) {
            OutputContours()
        } else {
            OutputPolymesh(elementType, polySize)
        }

        if (UsePooling) {
            _mesh?.Free()
        }
        _mesh = nil
    }
}
