#!/usr/bin/env bash
set -euo pipefail
export LANG=C.UTF-8
export PYTHONIOENCODING=utf-8

source_root="${DDSCLIENT_SOURCE_ROOT:-/workspace}"
rti_home="${DDSCLIENT_RTI_HOME:-/opt/rti}"
generated_dir="${DDSCLIENT_GENERATED_DIR:-/generated}"
output_root="${DDSCLIENT_OUTPUT_ROOT:-/out}"
package_name="${DDSCLIENT_PACKAGE_NAME:-DDSClient-CPP-rocky9-x64}"
include_rti_runtime="${DDSCLIENT_INCLUDE_RTI_RUNTIME:-OFF}"
skip_tests="${DDSCLIENT_SKIP_TESTS:-ON}"
build_cli="${DDSCLIENT_BUILD_CLI:-OFF}"
rti_platform_name="${DDSCLIENT_RTI_PLATFORM:-}"
rti_product_version="${DDSCLIENT_RTI_PRODUCT_VERSION:-unknown}"
build_dir=/tmp/ddsclient-build
install_dir="${output_root}/${package_name}"

case "${include_rti_runtime}" in
    ON|OFF) ;;
    *) echo "DDSCLIENT_INCLUDE_RTI_RUNTIME은 ON 또는 OFF여야 합니다." >&2; exit 2 ;;
esac
case "${skip_tests}" in
    ON|OFF) ;;
    *) echo "DDSCLIENT_SKIP_TESTS는 ON 또는 OFF여야 합니다." >&2; exit 2 ;;
esac
case "${build_cli}" in ON|OFF) ;; *) echo "잘못된 CLI 선택입니다." >&2; exit 2 ;; esac
build_tests=ON
if [[ "${skip_tests}" == ON ]]; then build_tests=OFF; fi

rm -rf "${build_dir}"
rm -rf "${install_dir}"

cmake -S "${source_root}/DDSCPP" -B "${build_dir}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DDDSCPP_ENABLE_RTI=ON \
    -DDDSCPP_RTI_HOME="${rti_home}" \
    -DDDSCPP_RTI_PLATFORM="${rti_platform_name}" \
    -DDDSCPP_RTI_PRODUCT_VERSION="${rti_product_version}" \
    -DDDSCPP_PREGENERATED_DIR="${generated_dir}" \
    -DDDSCPP_INSTALL_RTI_RUNTIME="${include_rti_runtime}" \
    -DDDSCPP_BUILD_TESTS="${build_tests}" \
    -DDDSCPP_BUILD_CLI="${build_cli}" \
    -DCMAKE_INSTALL_LIBDIR=lib64 \
    -DCMAKE_INSTALL_PREFIX="${install_dir}"
cmake --build "${build_dir}" --parallel
if [[ "${skip_tests}" == OFF ]]; then
    ctest --test-dir "${build_dir}" --output-on-failure
fi
cmake --install "${build_dir}"

test -f "${install_dir}/lib64/libdds_cpp.a"
test -f "${install_dir}/lib64/libdds_cpp.so"
if [[ -n "${rti_platform_name}" ]]; then
    rti_platform="${rti_home}/lib/${rti_platform_name}"
else
    rti_platform="$(find "${rti_home}/lib" -mindepth 1 -maxdepth 1 -type d -name 'x64Linux*' | sort -V | tail -n 1)"
fi
if [[ -z "${rti_platform}" ]]; then
    echo "${rti_home}/lib 아래에 x64Linux RTI 대상 폴더가 없습니다." >&2
    exit 3
fi
file "${install_dir}/lib64/libdds_cpp.a" "${install_dir}/lib64/libdds_cpp.so"
readelf -h "${install_dir}/lib64/libdds_cpp.so"
readelf -d "${install_dir}/lib64/libdds_cpp.so"
LD_LIBRARY_PATH="${rti_platform}:${install_dir}/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
    ldd "${install_dir}/lib64/libdds_cpp.so"

if [[ "${skip_tests}" == OFF ]]; then
for linkage in shared static; do
    consumer_build="/tmp/ddsclient-consumer-${linkage}"
    static_flag=OFF
    if [[ "${linkage}" == static ]]; then static_flag=ON; fi
    rm -rf "${consumer_build}"
    cmake -S "${source_root}/DDSCPP/tests/consumer" -B "${consumer_build}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_PREFIX_PATH="${install_dir}" \
        -DDDSClient_RTI_HOME="${rti_home}" \
        -DDDSClient_USE_STATIC_LIBS="${static_flag}"
    cmake --build "${consumer_build}" --parallel
    LD_LIBRARY_PATH="${rti_platform}:${install_dir}/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
        "${consumer_build}/ddsclient_consumer"
done
fi

cat > "${install_dir}/PACKAGE-MANIFEST.txt" <<EOF
DDSClient C++ 패키지
대상: ${package_name}
빌드 구성: Release
라이브러리: 공유 및 정적
RTI 실행 라이브러리 포함: ${include_rti_runtime}
RTI 제품 버전: ${rti_product_version}
RTI 대상 플랫폼: $(basename "${rti_platform}")
실행 설정: share/dds_cpp/definitions/qos_profiles.xml
메시지 정의: 빌드 시 XML에서 생성해 메시지 라이브러리에 포함
EOF

tar -C "${output_root}" -czf "${output_root}/${package_name}.tar.gz" "${package_name}"
(
    cd "${output_root}"
    sha256sum "${package_name}.tar.gz" > "${package_name}.tar.gz.sha256"
)

echo "Linux 패키지 생성 완료: ${output_root}/${package_name}.tar.gz"
