#!/bin/bash
# set  -x 
script_name=$(basename $0)
this_script=$(realpath $0)
root_dir=$(dirname $this_script)
# Declare an associative array
declare -A my_projects

####################################################################################################
####################################################################################################
####################################################################################################

declare_main_global_props () {
  project=$(basename $1)
  project_path=$(realpath $1)
  expected_version=$2
  # Initialize the associative array. Proejct => path
  my_projects=(
    ["com.mycompany.my-lib1"]="project-lib1"
    ["com.mycompany.my-lib2"]="project-lib2"
    ["com.mycompany.my-lib3"]="project-lib3"
  )
}

log () {
  echo "[INFO][$project] $@"
}

log_wrn () {
  echo "[WARNING][$project] $@" >&1
}

log_err () {
  echo "[ERROR][$project] $@" >&1
}

# Function to check if a version is available in the Maven repository
is_version_available() {
  local project=$1
  local version=$2
  ! (get_missing_dependencies | grep -c $project)
  return $?
}

# Function to wait for a version to be available in the Maven repository
wait_for_dependency_version() {
  local dependency_definition=$1
  local dep_group=$(echo $dependency_definition | cut -d':' -f1)
  local dep_artifact=$(echo $dependency_definition | cut -d':' -f2)
  local dep_version=$(echo $dependency_definition | cut -d':' -f4)
  local dep_project="${dep_group}.${dep_artifact}"

  local max_attempts=20
  local attempt=1
  local sleep_time=30

  log "Waiting for $dep_project:$dep_version to be ready..."

  until is_version_available $dep_project $dep_version; do
    if [ $attempt -ge $max_attempts ]; then
      log "Error: $dep_project:$dep_version is not available after $max_attempts attempts."
      return 1
    fi

    log "Attempt $attempt/$max_attempts: $dep_project:$dep_version is not available yet. Retrying in $sleep_time seconds..."
    attempt=$((attempt + 1))
    sleep $sleep_time
  done

  log "$dep_project:$dep_version is now available in the Maven repository."
  return 0
}


# Function to get missing dependencies from pom.xml
get_missing_dependencies() {
  # [WARNING] The POM for com.mycompany:my-lib1:jar:1.2.0 is missing, no dependency information available
  mvn -U dependency:tree |  sed -E -n "s/.* for (.*) is missing, no dependency information available.*/\1/p"
}

# check if a package match our domain
is_our_project () {
  local project=$1
  [[ -n ${my_projects[$project]} ]]
  return $?
}

build_dependency () {
  local dep_project_path="$1"
  local dep_version="$2"
  $this_script $dep_project_path $dep_version
}

# check_and_build_dependency com.mycompany:app:jar:1.0.0
check_and_build_dependency() {
  local dependency_definition=$1
  local dep_group=$(echo $dependency_definition | cut -d':' -f1)
  local dep_artifact=$(echo $dependency_definition | cut -d':' -f2)
  local dep_version=$(echo $dependency_definition | cut -d':' -f4)
  local dep_project="${dep_group}.${dep_artifact}"

  if ! is_version_available $dep_project $dep_version; then
    if is_our_project $dep_project $dep_version ; then 
      local dep_project_path="$root_dir/${my_projects[$dep_project]}"
      log launching build $dep_project_path in parallel
      build_dependency $dep_project_path $dep_version &
    else 
      log_err "cant build $dependency_definition package unknown" >&2
      return 1
    fi
  fi
}

# Function to check and push dependencies
check_and_build_dependencies() {
  local project=$1
  local missing_dependencies=$(get_missing_dependencies)

  if [[ "$missing_dependencies" != "" ]]; then
    log_wrn "#################"  
    log_wrn "[WARNING] missing dependencies: "  
    log_wrn "$missing_dependencies"  
    log_wrn "#################" 
    for dep in $missing_dependencies; do
      check_and_build_dependency $dep
    done

    for dep in $missing_dependencies; do
      wait_for_dependency_version $dep
    done

  fi
  return $?
}

git_get_current_branch () {
  git rev-parse --abbrev-ref HEAD
}

git_current_branch_is_release () {
  [[ $(git rev-parse --abbrev-ref HEAD) =~ ^release\/.*$ ]]
  return $?
}

get_current_version () {
   mvn help:evaluate -Dexpression=project.version -q -DforceStdout
}

does_match_expected () {
  [[ "$1" =~ ^${2}(-.*)?$ ]]
  return $?
}

git_flow_release_start () {
    # on uncommitted changes exit 
    if ! git diff-index --quiet HEAD -- ;    then
      log_wrn "there are local modifications"  
      return 1
    fi 

    local master_branch=$(git config gitflow.branch.master)
    local develop_branch=$(git config gitflow.branch.develop)
    local release_prefix=$(git config gitflow.prefix.release)

    git checkout $develop_branch
    local curr_version=$(get_current_version)

    if ! does_match_expected "$curr_version" "$expected_version" ; then
      log_err "project version <${curr_version}> does not match expected version <${expected_version}>" 
      return 5
    fi

    if ! git_current_branch_is_release ;    then
      git checkout $master_branch && git pull origin $master_branch || return 2
      git checkout $develop_branch && git pull origin $develop_branch || return 3
      git checkout $release_prefix$expected_version 2>/dev/null || git frs 
    fi
    git_current_branch_is_release
    return $?
}


mvn_install () {
  # on real execution we should only rely in git frf to push 
  echo "Emulating jenkins build"
  sleep 20
  mvn install
}

git_flow_release_finish () {
  mvn_install && git frf
  return $?
}

run_close_release () {
  git_flow_release_start $project || return 1
  # Check and push dependencies if necessary
  check_and_build_dependencies $project || return 2
  git_flow_release_finish
  # TODO git_flow_release_finish
}

# run the main 
run_close_release_exclusively () {
    lockfile=".${script_name}.lock"
    statusfile=".${script_name}.status"

    # Use flock to ensure only one process can create the lock file
    exec 200>"$lockfile"

    if flock -n 200; then
        # Run the common task
        if run_close_release; then
            echo "success" > "$statusfile"
        else
            echo "failure" > "$statusfile"
        fi
        # Release the lock
        flock -u 200
    else
        # Wait for the common task to complete
        log_wrn "Waiting another instance of run_close_release to complete..."
        flock 200
        # Check the status of the common task
        if [ "$(cat $statusfile)" == "failure" ]; then
            log_err "Common task failed, exiting."
            exit 1
        else
            log "Common task completed successfully by another process."
        fi
    fi
}


check_args () {
  if [ -z "$1" ] || [ -z "$2" ] || [ ! -d "$1" ]; then
    log_err "Usage: $0 <project_dir> <expected_version>"
    exit 1
  fi
}

# Main script
main() {
  check_args $@
  declare_main_global_props $@
  cd $project_path
  log "in $project expecting to compile <${expected_version}>"

  run_close_release_exclusively
}

####################################################################################################
####################################################################################################
####################################################################################################

# Run the main script with the provided argument
main $1 $2
