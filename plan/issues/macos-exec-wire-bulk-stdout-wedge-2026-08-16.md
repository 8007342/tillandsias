# 772-qn6j evidence — macOS exec-wire bulk-stdout wedge (2026-08-16, git 7bc647f6 dist build)

binary: dist/Tillandsias.app/Contents/MacOS/tillandsias-tray (tillandsias-tray 0.1.0 (git 7bc647f6, built 2026-08-16T09:28:44Z))
roundtrip_1=9s
roundtrip_2=10s
roundtrip_3=9s
roundtrip_4=10s
roundtrip_5=10s
roundtrip_6=9s
roundtrip_7=10s
roundtrip_8=9s
chatty_200_lines=10s rc=2
payload_1MB=90s rc=124
payload_100KB=60s rc=124
postcondition_roundtrip=9s rc=0
payload_32KB=60s rc=124

## hang stack sample (trimmed; full file: target/idle-measure/147-hang-sample.txt on the macOS host)
Analysis of sampling tillandsias-tray (pid 43184) every 1 millisecond
Process:         tillandsias-tray [43184]
Path:            /Users/USER/*/Tillandsias.app/Contents/MacOS/tillandsias-tray
Load Address:    0x102a50000
Identifier:      com.tlatoani.tillandsias.tray
Version:         0.4 (0.4.260815.1)
Code Type:       ARM64
Platform:        macOS
Parent Process:  zsh [42889]
Target Type:     live task

Date/Time:       2026-08-16 06:23:48.640 -0700
Launch Time:     2026-08-16 05:25:17.801 -0700
OS Version:      macOS 26.6.1 (25G76)
Report Version:  7
Analysis Tool:   /usr/bin/sample

Physical footprint:         12.7M
Physical footprint (peak):  26.4M
Idle exit:                  untracked
----

Call graph:
    1571 Thread_2155218   DispatchQueue_1: com.apple.main-thread  (serial)
      1571 start  (in dyld) + 6992  [0x1882b84e4]
        1571 ???  (in tillandsias-tray)  load address 0x102a50000 + 0x86d2c  [0x102ad6d2c]
          1571 ???  (in tillandsias-tray)  load address 0x102a50000 + 0x4d7cc  [0x102a9d7cc]
            1571 ???  (in tillandsias-tray)  load address 0x102a50000 + 0x20fdc  [0x102a70fdc]
              1571 ???  (in tillandsias-tray)  load address 0x102a50000 + 0x28d14  [0x102a78d14]
                1571 ???  (in tillandsias-tray)  load address 0x102a50000 + 0x210b44  [0x102c60b44]
                  1571 ???  (in tillandsias-tray)  load address 0x102a50000 + 0x2107d4  [0x102c607d4]
                    1571 ???  (in tillandsias-tray)  load address 0x102a50000 + 0x20e320  [0x102c5e320]
                      1571 ???  (in tillandsias-tray)  load address 0x102a50000 + 0x20e600  [0x102c5e600]
                        1571 kevent  (in libsystem_kernel.dylib) + 8  [0x188645fc4]

Total number in stack (recursive counted multiple, when >=5):

Sort by top of stack, same collapsed (when >= 5):
        kevent  (in libsystem_kernel.dylib)        1571

Binary Images:
       0x102a50000 -        0x102dc719f +com.tlatoani.tillandsias.tray (0.4 - 0.4.260815.1) <5B424D44-FED2-3361-8D75-41795DA0FEF6> /Users/*/Tillandsias.app/Contents/MacOS/tillandsias-tray
       0x188210000 -        0x188262b4b  libobjc.A.dylib (951.7) <40277974-D20C-3EC8-B25C-43AE30D8CC60> /usr/lib/libobjc.A.dylib
       0x188263000 -        0x188297d58  libdyld.dylib (1387) <634959D0-592E-349C-B549-B91F2FF09858> /usr/lib/system/libdyld.dylib
       0x188298000 -        0x18834b4ff  dyld (1.0.0 - 1387) <DF42DD9D-AD11-33A7-8849-9AD5DF30A274> /usr/lib/dyld
       0x18834c000 -        0x18834f228  libsystem_blocks.dylib (96) <A712B95E-BCEE-3F12-9F9B-58E6C2060E53> /usr/lib/system/libsystem_blocks.dylib
       0x188350000 -        0x1883a455f  libxpc.dylib (3102.160.5) <40BBE226-77D4-332E-9DA8-F0B5BACFB86D> /usr/lib/system/libxpc.dylib
       0x1883a5000 -        0x1883c59ff  libsystem_trace.dylib (1861.160.4) <E043667E-AD01-3228-837F-A381F32F2B30> /usr/lib/system/libsystem_trace.dylib
       0x1883c6000 -        0x1884745f7  libcorecrypto.dylib (1922.160.10) <D54389FC-4078-370D-A863-9FEF16E00DFD> /usr/lib/system/libcorecrypto.dylib
       0x188475000 -        0x1884c5257  libsystem_malloc.dylib (812.160.5) <971CDCFE-4D20-300E-A1D6-EC8672FDD258> /usr/lib/system/libsystem_malloc.dylib
       0x1884c6000 -        0x18850d23f  libdispatch.dylib (1542.160.2) <243E06A0-7BFF-3C3F-8A9B-D7732729B361> /usr/lib/system/libdispatch.dylib
       0x18850e000 -        0x188510ffb  libsystem_featureflags.dylib (103) <5E7CDBD5-44AB-34C0-A0F5-FC72F6116CDC> /usr/lib/system/libsystem_featureflags.dylib
       0x188511000 -        0x1885921e7  libsystem_c.dylib (1752.160.4) <FDC4E366-5C14-3A1E-BC35-D933D28CDCF3> /usr/lib/system/libsystem_c.dylib
       0x188593000 -        0x188623ae7  libc++.1.dylib (2100.43) <C6DC2145-7B94-3E01-ADE5-96A6C2D078BC> /usr/lib/libc++.1.dylib
       0x188624000 -        0x18863e75f  libc++abi.dylib (2100.43) <DDE77B06-5E25-380B-85B7-BA1A27D09021> /usr/lib/libc++abi.dylib
       0x18863f000 -        0x18867c2e7  libsystem_kernel.dylib (12377.161.13) <7CFB3A10-ADB2-32C4-99B5-922A111B3224> /usr/lib/system/libsystem_kernel.dylib
       0x18867d000 -        0x188689b3b  libsystem_pthread.dylib (539.100.4) <12342372-0084-37A5-9EA6-2E4DC940C685> /usr/lib/system/libsystem_pthread.dylib
       0x18868a000 -        0x188692963  libsystem_platform.dylib (375.120.2) <4C6BD0FE-25F2-38D8-BE5C-24DAC1DEDCFB> /usr/lib/system/libsystem_platform.dylib
       0x188693000 -        0x1886c26eb  libsystem_info.dylib (600) <7402662E-F235-3F48-BB65-F64C8CF0F2BB> /usr/lib/system/libsystem_info.dylib
       0x1886c3000 -        0x188c2153f  com.apple.CoreFoundation (6.9 - 5026.6.7) <FDBA2243-A7AB-3524-9B94-F3034AC36E41> /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation
