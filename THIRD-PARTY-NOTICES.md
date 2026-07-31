# Third-party distribution notes

The offline source package contains unmodified installers or binary images from
third parties. Review the applicable license and your organization's software
distribution policy before redistributing the package outside your organization.

- Microsoft .NET SDK installer: Microsoft license terms supplied by Microsoft
- CMake installer: Kitware/CMake licensing terms
- Python installer: Python Software Foundation license
- Rocky Linux builder image: Rocky Linux base image plus distribution packages,
  including GCC, CMake, binutils, Python, and their respective licenses
- Docker Desktop: required for the Windows-hosted Linux build, but not bundled
- RTI Connext DDS: not bundled in the source package; a separately licensed RTI
  installation and target libraries are required

RTI runtime libraries are excluded from the generated Linux package by default.
`build-linux.ps1 -IncludeRtiRuntime` should only be used after confirming the RTI
license and redistribution terms that apply to the intended delivery.
