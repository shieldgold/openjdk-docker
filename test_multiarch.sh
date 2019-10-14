#!/usr/bin/env bash
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
set -o pipefail

root_dir="$PWD"
source_prefix="adoptopenjdk"
source_repo="openjdk"
version="9"
tag_aliases=""
arch_tags=""
man_file=${root_dir}/manifest_commands.sh

source ./common_functions.sh

if [ $# -ne 3 ]; then
	echo
	echo "usage: $0 version vm package"
	echo "version = ${supported_versions}"
	echo "vm      = ${all_jvms}"
	echo "package = ${all_packages}"
	exit -1
fi

set_version $1
vm=$2
package=$3

# Run a java -version test for a given docker image.
function test_java_version() {
	img=$1

	echo
	echo "TEST: Running java -version test on image: ${img}..."
	# Don't use "-it" flags as the jenkins job doesn't have a tty
	docker run --rm ${img} java -version
	if [ $? != 0 ]; then
		echo "ERROR: Docker Image ${img} failed the java -version test\n"
		exit 1
	fi
	echo
}

# Run all test buckets for the given image.
function run_tests() {
	img=$1

	for test_case in $(cat ${test_buckets_file} | grep -v "^#")
	do
		${test_case} ${img}
	done
}

# Run tests on all the alias docker tags.
function test_aliases() {
	repo=$1
	target_repo=${source_prefix}/${repo}

	# Check if all the individual docker images exist for each expected arch
	for arch_tag in ${arch_tags}
	do
		echo -n "INFO: Pulling image: ${target_repo}:${arch_tag}..."
		ret=$(check_image ${target_repo}:${arch_tag})
		if [ ${ret} != 0 ]; then
			echo "Error: Docker Image ${img} not found on hub.docker\n"
			exit 1
		fi
	done

	# Global variable tag_aliases has the alias list
	for tag_alias in ${tag_aliases}
	do
		echo -n "INFO: Pulling image: ${target_repo}:${tag_alias}..."
		ret=$(check_image ${target_repo}:${tag_alias})
		if [ ${ret} != 0 ]; then
			echo "Error: Docker Image ${img} not found on hub.docker\n"
			exit 1
		fi
		run_tests ${target_repo}:${tag_alias}
	done
}

# Check each of the images in the global variable arch_tags exist
# and run tests on them
function test_tags() {
	repo=$1
	target_repo=${source_prefix}/${repo}

	# Check if all the individual docker images exist for each expected arch
	for arch_tag in ${arch_tags}
	do
		tarch=$(echo ${arch_tag} | awk -F"-" '{ print $1 }')
		if [ ${tarch} != ${current_arch} ]; then
			continue;
		fi
		echo -n "INFO: Pulling image: ${target_repo}:${arch_tag}..."
		ret=$(check_image ${target_repo}:${arch_tag})
		if [ ${ret} != 0 ]; then
			echo "Error: Docker Image ${img} not found on hub.docker\n"
			exit 1
		fi
		run_tests ${target_repo}:${arch_tag}
	done
}

# Run tests for each of the test image types
# Currently image types = test_tags and test_aliases.
function test_image_types() {
	srepo=$1

	for test_image in $(cat ${test_image_types_file} | grep -v "^#")
	do
		${test_image} ${srepo}
	done
}

# Set the OSes that will be built on based on the current arch
set_arch_os

# Which JVMs are available for the current version
./generate_latest_sums.sh ${version}

# Source the hotspot and openj9 shasums scripts
available_jvms=""
if [ "${vm}" == "hotspot" -a -f hotspot_shasums_latest.sh ]; then
	source ./hotspot_shasums_latest.sh
	available_jvms="hotspot"
fi
if [ "${vm}" == "openj9" -a -f openj9_shasums_latest.sh ]; then
	source ./openj9_shasums_latest.sh
	available_jvms="${available_jvms} openj9"
fi

# Go through each vm / os / build / type combination and build the manifest commands
# vm    = hotspot / openj9
# os    = alpine / ubuntu
# build = releases / nightly
# type  = full / slim
for os in ${oses}
do
	builds=$(parse_vm_entry ${vm} ${version} ${package} ${os} "Build:")
	btypes=$(parse_vm_entry ${vm} ${version} ${package} ${os} "Type:")
	for build in ${builds}
	do
		shasums="${package}"_"${vm}"_"${version}"_"${build}"_sums
		jverinfo=${shasums}[version]
		eval jrel=\${$jverinfo}
		if [[ -z ${jrel} ]]; then
			continue;
		fi
		# Docker image tags cannot have "+" in them, replace it with "_" instead.
		rel=$(echo ${jrel} | sed 's/+/_/g')

		srepo=${source_repo}${version}
		if [ "${vm}" != "hotspot" ]; then
			srepo=${srepo}-${vm}
		fi
		for btype in ${btypes}
		do
			echo -n "INFO: Building tag list for [${vm}]-[${os}]-[${build}]-[${btype}]..."
			# Get the relevant tags for this vm / os / build / type combo from the tags.config file.
			raw_tags=$(parse_tag_entry ${os} ${package} ${build} ${btype})
			# Build tags will build both the arch specific tags and the tag aliases.
			build_tags ${vm} ${version} ${package} ${rel} ${os} ${build} ${raw_tags}
			echo "done"
			# Test both the arch specific tags and the tag aliases.
			test_image_types ${srepo}
		done
	done
done

echo "INFO: Test complete"
