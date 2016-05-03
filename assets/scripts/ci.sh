#!/bin/bash

export GITHUB_USER=${GITHUB_USER:-phuslu}
export GITHUB_REPO=${GITHUB_REPO:-goproxy}
export GITHUB_CI_REPO=${GITHUB_CI_REPO:-goproxy-ci}
export GITHUB_COMMIT_ID=${TRAVIS_COMMIT:-${COMMIT_ID:-master}}
export WORKING_DIR=/tmp/${GITHUB_REPO}.$(date "+%Y%m%d").${RANDOM:-$$}
export GOROOT_BOOTSTRAP=${WORKING_DIR}/go1.6
export GOROOT=${WORKING_DIR}/go
export GOPATH=${WORKING_DIR}/gopath
export PATH=$GOROOT/bin:$GOPATH/bin:$PATH

if [ ${#GITHUB_TOKEN} -eq 0 ]; then
	echo "\$GITHUB_TOKEN is not set, abort"
	exit 1
fi

for CMD in curl awk git tar bzip2 xz 7za gcc; do
	if ! $(which ${CMD} >/dev/null 2>&1); then
		echo "tool ${CMD} is not installed, abort."
		exit 1
	fi
done

mkdir -p ${WORKING_DIR}

function init_github() {
	pushd ${WORKING_DIR}

	git config --global user.name ${GITHUB_USER}
	git config --global user.email "${GITHUB_USER}@noreply.github.com"

	if ! grep -q 'machine github.com' ~/.netrc; then
		(set +x; echo "machine github.com login $GITHUB_USER password $GITHUB_TOKEN" >>~/.netrc)
	fi

	popd
}

function build_go() {
	pushd ${WORKING_DIR}

	curl -k https://storage.googleapis.com/golang/go1.6.linux-amd64.tar.gz | tar xz
	mv go go1.6

	git clone https://github.com/phuslu/go
	cd go/src
	git remote add -f upstream https://github.com/golang/go
	git rebase upstream/master
	BUILD_GO_TAG_BACK_STEPS=~3 bash ./make.bash
	git push -f origin master

	(set +x; \
		echo '================================================================================' ;\
		cat /etc/issue ;\
		uname -a ;\
		echo ;\
		go version ;\
		go env ;\
		echo ;\
		env | grep -v GITHUB_TOKEN ;\
		echo '================================================================================' ;\
	)

	popd
}

function build_glog() {
	pushd ${WORKING_DIR}

	git clone https://github.com/phuslu/glog $GOPATH/src/github.com/phuslu/glog
	cd $GOPATH/src/github.com/phuslu/glog
	git remote add -f upstream https://github.com/golang/glog
	git rebase upstream/master
	go build -v
	git push -f origin master

	popd
}

function build_http2() {
	pushd ${WORKING_DIR}

	git clone https://github.com/phuslu/net $GOPATH/src/github.com/phuslu/net
	cd $GOPATH/src/github.com/phuslu/net/http2
	git remote add -f upstream https://github.com/golang/net
	git rebase upstream/master
	go build -v
	git push -f origin master

	popd
}

function build_repo() {
	pushd ${WORKING_DIR}

	git clone --branch "master" https://github.com/${GITHUB_USER}/${GITHUB_REPO} ${GITHUB_REPO}

	cd ${GITHUB_REPO}
	git checkout -f ${GITHUB_COMMIT_ID}

	export RELEASE=$(git rev-list HEAD| wc -l | xargs)
	export RELEASE_DESCRIPTION=$(git log -1 --oneline --format="r${RELEASE}: [\`%h\`](https://github.com/${GITHUB_USER}/${GITHUB_REPO}/commit/%h) %s")
	if [ -n "${TRAVIS_BUILD_ID}" ]; then
		export RELEASE_DESCRIPTION=$(echo ${RELEASE_DESCRIPTION} | sed -E "s#^(r[0-9]+)#[\1](https://travis-ci.org/${GITHUB_USER}/${GITHUB_REPO}/builds/${TRAVIS_BUILD_ID})#g")
	fi

	awk 'match($1, /"((github\.com|golang\.org|gopkg\.in)\/.+)"/) {if (!seen[$1]++) {gsub("\"", "", $1); print $1}}' $(find . -name "*.go") | xargs -n1 -i go get -v {}

	for OSARCH in linux/amd64 linux/386 linux/arm linux/arm64 linux/mips64 linux/mips64le darwin/amd64 darwin/386 windows/amd64 windows/386; do
		make GOOS=${OSARCH%/*} GOARCH=${OSARCH#*/}
		mkdir -p ${WORKING_DIR}/r${RELEASE}
		cp -r build/dist/* ${WORKING_DIR}/r${RELEASE}
		make clean
	done

	(cd ${WORKING_DIR}/r${RELEASE}/ && ls -lht)

	popd
}

function release_repo_ci() {
	if [ "$TRAVIS_PULL_REQUEST" == "true" ]; then
		return
	fi

	pushd ${WORKING_DIR}

	git clone --branch "master" https://github.com/${GITHUB_USER}/${GITHUB_CI_REPO} ${GITHUB_CI_REPO}
	cd ${GITHUB_CI_REPO}

	git commit --allow-empty -m "release"
	git tag -d r${RELEASE} || true
	git tag r${RELEASE}
	git push -f origin r${RELEASE}

	cd ${WORKING_DIR}
	local GITHUB_RELEASE_URL=https://github.com/aktau/github-release/releases/download/v0.6.2/linux-amd64-github-release.tar.bz2
	local GITHUB_RELEASE_BIN=$(pwd)/$(curl -L ${GITHUB_RELEASE_URL} | tar xjpv | head -1)

	cd ${WORKING_DIR}/r${RELEASE}/
	${GITHUB_RELEASE_BIN} delete --user ${GITHUB_USER} --repo ${GITHUB_CI_REPO} --tag r${RELEASE} >/dev/null 2>&1 || true
	sleep 1
	${GITHUB_RELEASE_BIN} release --user ${GITHUB_USER} --repo ${GITHUB_CI_REPO} --tag r${RELEASE} --name "${GITHUB_REPO} r${RELEASE}" --description "${RELEASE_DESCRIPTION}"

	for FILE in *; do
		${GITHUB_RELEASE_BIN} upload --user ${GITHUB_USER} --repo ${GITHUB_CI_REPO} --tag r${RELEASE} --name ${FILE} --file ${FILE}
	done

	popd
}

function clean() {
	(cd ${WORKING_DIR}/r${RELEASE}/ && ls -lht && md5sum *)
	rm -rf ${WORKING_DIR}
}

init_github
build_go
build_glog
build_http2
build_repo
release_repo_ci
clean
