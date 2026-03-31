import Foundation

// MARK: - SkyLight Private API Declarations

@_silgen_name("SLSMainConnectionID")
package func SLSMainConnectionID() -> Int32

@_silgen_name("SLSGetActiveSpace")
package func SLSGetActiveSpace(_ cid: Int32) -> Int

@_silgen_name("SLSCopyManagedDisplaySpaces")
package func SLSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray

@_silgen_name("SLSSpaceGetType")
package func SLSSpaceGetType(_ cid: Int32, _ space: Int) -> Int32
