Pod::Spec.new do |s|
  s.name             = 'flutter_watchos'
  s.version          = '0.1.0'
  s.summary          = 'Platform detection and utilities for Flutter on watchOS (FFI).'
  s.description      = <<-DESC
Provides runtime checks to determine if a Flutter app is running on Apple Watch
(watchOS), along with device information, capability queries, and Taptic Engine
haptics. Uses dart:ffi for synchronous native calls with zero async overhead.
                       DESC
  s.homepage         = 'https://flutterwatch.dev'
  s.license          = { :type => 'BSD', :file => '../LICENSE' }
  s.author           = { 'FlutterWatch' => 'info@flutterwatch.dev' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/flutter_watchos_ffi.{h,m}'
  s.public_header_files = 'Classes/flutter_watchos_ffi.h'

  s.platform         = :watchos, '7.0'
  s.watchos.deployment_target = '7.0'

  s.frameworks       = 'WatchKit', 'Foundation'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
  }
end
