# DDSClient — source build

Umbrella repository for the DDS client stack. It carries the C# and C++ client
repositories as submodules and drives a full, reproducible build of both from a single
entry point — including a fully offline build on a machine that has never seen the
internet.

## Getting the sources

```powershell
git clone --recurse-submodules https://github.com/saturnone1/DDSClient.git
```

Already cloned without submodules:

```powershell
git submodule update --init --recursive
```

The .NET, CMake and Python installers, the Rocky Linux builder image and the finished
distribution packages are **not committed** — GitHub's file size limits make that
impractical. They ship as GitHub Release assets on this repository instead. For a
completely offline build, use `DDSClient-Source-Build-windows-x64.zip` from the Release.

If you are on Windows, need to edit `DDSSim.xml`, and want to rebuild both the C# and C++
libraries, follow the [offline Windows build guide](BUILD-WINDOWS-OFFLINE.md).

## Building

If Visual Studio and RTI Connext DDS are already installed on the target machine, start
with the combined diagnostic:

```powershell
.\build.ps1 -Doctor
```

After installing the bundled .NET SDK, CMake and Python, this regenerates all types and
builds Windows C#/C++ and Linux C++ in one pass:

```powershell
.\build.ps1 -Target All -StartDocker -Force
```

Either target can be built on its own:

```powershell
.\build.ps1 -Target Windows
.\build.ps1 -Target Linux -Force
```

## Offline source package

To produce the ZIP handed to another machine:

```powershell
.\create-source-package.ps1
```

It bundles the Linux build scripts and Docker configuration alongside the sources, so the
receiving machine can build both targets without network access.

## Linux C++ from Windows

To build the static and shared C++ libraries for Rocky Linux 9 x64 from a Windows host,
start Docker Desktop's Linux container engine and run:

```powershell
.\build-linux.ps1
```

The output contains `libdds_cpp.a`, `libdds_cpp.so`, a CMake consumer package and
verification checksums. See [BUILD-LINUX.md](BUILD-LINUX.md) for the full procedure.

## A note on version numbers

The RTI product version and the target directory name are versioned independently and
will not match. RTI Connext 7.3.1, for example, builds into a Linux target folder named
`x64Linux4gcc7.3.0`. This is expected — do not "correct" one to the other.

## Just consuming the libraries?

Developers who use the prebuilt libraries and never change the message definitions should
read `DDSClient-Developer-Package/README.md` instead of this file.
