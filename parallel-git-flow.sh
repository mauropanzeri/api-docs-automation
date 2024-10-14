#!/bin/bash
# set  -x 
script_name=$(basename $0)
this_script=$(realpath $0)
root_dir=$(dirname $this_script)
lock_dir="${root_dir}/var/locks"
# Declare an associative array
declare -A my_projects_repo
declare -A my_projects

####################################################################################################
####################################################################################################
####################################################################################################

#########
## Script handling
#########
declare_main_global_props () {
  project=$(basename $1)
  project_path=$(realpath $1)
  expected_version=$2
  # Initialize the associative array. Proejct => path
  my_projects_repo=(
    ["com.mycompany.my-lib1"]=".project-lib1.git"
    ["com.mycompany.my-lib2"]=".project-lib2.git"
    ["com.mycompany.my-lib3"]=".project-lib3.git"
  )
  my_projects=(
    ["com.mycompany.my-lib1"]="project-lib1"
    ["com.mycompany.my-lib2"]="project-lib2"
    ["com.mycompany.my-lib3"]="project-lib3"
  )
}

check_args () {
  if [ -z "$1" ] || [ -z "$2" ] || [ ! -d "$1" ]; then
    log_err "Usage: $0 <project_dir> <expected_version>"
    exit 1
  fi
}

#########
## Logging
#########


logged_command () {
  prefix=$1
  shift
  command=$@
  # Run the command and prefix each line of its output
  $command 2>&1 | while IFS= read -r line; do
    echo "$prefix$line"
  done
  # Capture the exit code of the command
  return ${PIPESTATUS[0]}
}

_date () {
  date +"%Y-%m-%dT%H:%M:%S"
}

_echo () {
  logged_command "[${project}][$(_date)]" echo $@
  return $?
}

_mvn () {
  logged_command "[${project}][$(_date)][mvn]" mvn $@
  return $? 
}

_git () {
  logged_command "[${project}][$(_date)][git]" git $@
  return $? 
}


log () {
  _echo "[INFO] $@"
}

log_wrn () {
  _echo "[WARNING] $@" >&2
}

log_err () {
  _echo "[ERROR] $@" >&2
}

#########
## misc
#########


# 1.2.X X == 0 => hotfix
is_version_number_hotfix () {
  version=$1
  # Extract the patch level
  patch_level=$(echo $version | cut -d. -f3 | cut -d- -f1)
  
  ! [[ -z "$patch_level" || "$patch_level" -eq 0 ]]
  return  $?
}

# check if 2 version are identical excpect for the suffix
does_match_expected () {
  [[ "$1" =~ ^${2}(-.*)?$ ]]
  return $?
}

#########
## Package manager
#########


mvn_install () {
  # on real execution we should only rely in git frf to push 
  log "Emulating jenkins build"
  sleep 20
  _mvn install
}

# Function to check if a version is available in the Maven repository
is_version_available() {
  local dep_project=$1
  local dep_version=$2
  ! (get_missing_dependencies | grep -c $dep_project)
  return $?
}

# Function to wait for a version to be available in the Maven repository
wait_for_dependency_version() {
  local dependency_definition=$1
  local dep_group=$(echo $dependency_definition | cut -d':' -f1)
  local dep_artifact=$(echo $dependency_definition | cut -d':' -f2)
  local dep_version=$(echo $dependency_definition | cut -d':' -f4)
  local dep_project="${dep_group}.${dep_artifact}"

  local max_attempts=30
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
  _mvn -U dependency:tree |  sed -E -n "s/.* for (.*) is missing, no dependency information available.*/\1/p"
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
      build_dependency $dep_project_path $dep_version
    else 
      log_err "cant build $dependency_definition package unknown" >&2
      return 1
    fi
  fi
}

# Function to check and push dependencies
check_and_build_dependencies() {
  local missing_dependencies=$(get_missing_dependencies)

  if [[ "$missing_dependencies" != "" ]]; then
    log_wrn "#################"  
    log_wrn "[WARNING] missing dependencies: "  
    log_wrn "$missing_dependencies"  
    log_wrn "#################" 
    for dep in $missing_dependencies; do
      check_and_build_dependency $dep &
    done
    wait

    for dep in $missing_dependencies; do
      wait_for_dependency_version $dep
    done

  fi
  log "all dependencies ready: verifying"
  _mvn -ntp verify -P-webapp
  return $?
}

#########
## Git
#########


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


git_flow_hotfix_check () {
  local master_branch=$(git config gitflow.branch.master)
  local hotfix_prefix=$(git config gitflow.prefix.hotfix)
  local hotfix_branch="${hotfix_prefix}${expected_version}"
  _git checkout $hotfix_prefix  || return 3
  _git pull origin $hotfix_branch

  # on uncommitted changes exit 
  if ! git diff-index --quiet HEAD -- ;    then
    log_wrn "there are local modifications"  
    return 1
  fi   

  local curr_version=$(get_current_version)
  if ! does_match_expected "$curr_version" "$expected_version" ; then
    log_err "project version <${curr_version}> does not match expected version <${expected_version}>" 
    return 5
  fi
}

git_flow_release_check_and_start () {
  local master_branch=$(git config gitflow.branch.master)
  local develop_branch=$(git config gitflow.branch.develop)
  local release_prefix=$(git config gitflow.prefix.release)

  _git checkout $develop_branch && _git pull origin $develop_branch || return 3
  
  # on uncommitted changes exit 
  if ! git diff-index --quiet HEAD -- ;    then
    log_wrn "there are local modifications"  
    return 1
  fi 

  local curr_version=$(get_current_version)
  if ! does_match_expected "$curr_version" "$expected_version" ; then
    log_err "project version <${curr_version}> does not match expected version <${expected_version}>" 
    return 5
  fi

  if ! git_current_branch_is_release ;    then
    _git checkout $master_branch && _git pull origin $master_branch || return 2
    master_version=$(get_current_version)

    higher_version=$(echo -e "${master_version}\n${expected_version}" | sort -V -r | head -n 1)
    if [[ "$higher_version" != "$expected_version" ]]; then
      log_err "<${expected_version}> is lower than <${higher_version}> " 
      return 4
    fi

    # if the release branch of the expected version exists, use that, otherwise
    # start the release
    _git checkout "${release_prefix}${expected_version}" 2>/dev/null \
      || _git frs 
  fi
  git_current_branch_is_release
  return $?
}


git_flow_release_finish () {
  mvn_install && _git frf
  return $?
}


git_flow_hotfix_finish () {
  mvn_install && _git fhf
  return $?
}

#########
## Git flow coordination
#########

run_close_release () {
  git_flow_release_check_and_start || return 1
  # Check and push dependencies if necessary
  check_and_build_dependencies || return 2
  git_flow_release_finish || return 3
}


run_close_hotfix () {
  git_flow_hotfix_check
  # Check and push dependencies if necessary
  check_and_build_dependencies || return 2
  git_flow_hotfix_finish  || return 3
}

run_close_version () {
  if is_version_number_hotfix $expected_version ; then
    log "closing hotfix $expected_version"
    run_close_hotfix
  else
    log "closing release $expected_version"
    run_close_release
  fi
}

# run the main 
run_close_version_exclusively () {
  mkdir -p "${lock_dir}"
  lockfile="${lock_dir}/.${project}.lock"
  statusfile="${lock_dir}/.${project}.status"

  # Use flock to ensure only one process can create the lock file
  exec 200>"$lockfile"

  if flock -n 200; then
      # Run the common task
      if run_close_version; then
          echo "success" > "$statusfile"
      else
          echo "failure" > "$statusfile"
      fi
      # Release the lock
      flock -u 200
  else
      # Wait for the common task to complete
      log_wrn "Waiting another instance of run_close_version to complete..."
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



# Main script
main() {
  check_args $@
  declare_main_global_props $@
  cd $project_path
  log "in $project expecting to compile <${expected_version}>"

  run_close_version_exclusively
}

####################################################################################################
####################################################################################################
####################################################################################################

# Run the main script with the provided argument
main $1 $2
