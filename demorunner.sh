#!/bin/sh
#  start.sh
#
#
# Created by Maria Gabriella Brodi and Cora Iberkleid on 3/28/20.


COMMANDS_FILE="${1}"          # required
START_WITH_LINE_NUMBER="${2}" # optional
START_WITH_LINE_NUMBER="${START_WITH_LINE_NUMBER:-1}" # default to 1 if not provided

# If the 'commands file' does not exist, print usage instructions
# If a 'start with line number' argument was provided and it is not a number, print usage instructions
if [ ! -f "${COMMANDS_FILE}" ] || ([ $# -eq 2 ] && ! [[ "${START_WITH_LINE_NUMBER}" =~ ^[0-9]+$ ]]); then
  echo
  echo "Usage:"
  echo     "source ./demorunner.sh [commands-file]"
  echo     "source ./demorunner.sh [commands-file] [start-with-line-number]"
  echo
  echo "This script echoes and executes a list of commands that you provide in a \"commands file\". The file"
  echo "must exist for the demo script to run."
  echo
  echo "Use @_ECHO_ON & @_ECHO_OFF in the commands file to control whether or not commands are printed to the"
  echo "terminal before they are executed. If echo is turned off, commands are executed immediately. If echo is"
  echo "turned on, the script will wait for the user to hit Enter/Return before echoing each command, and again"
  echo "before executing the command. Commands are echoed slowly to the terminal to simulate live typing."
  echo
  echo "If you provide a number as a second input argument, the script will skip execution of any lines above that."
  echo "@_ECHO_ON & @_ECHO_OFF commands above the starting line will still be respected."
  echo
  echo "The default font color for echoed commands is yellow. You can change it to blue using:"
  echo "export DEMO_COLOR=blue"
  return
  echo
else
  echo "Executing commands in file ${COMMANDS_FILE} starting at line ${START_WITH_LINE_NUMBER}"
fi

RESET="\033[0m"
BOLD="\033[1m"
YELLOW="\033[38;5;11m"
BLUE="\033[0;34m"
ECHO=off

# Set color
if [[ $DEMO_COLOR == "blue" ]]; then
  COLOR="${BLUE}"
else
  COLOR="${YELLOW}"
fi

# Set terminal tab name to the file name minus the extension
printf "\e]1;%s\a" "${COMMANDS_FILE%.*}"

# Execute commands from file
let LINE_NUMBER=0
while IFS= read -r command; do
  ((LINE_NUMBER=LINE_NUMBER+1))

    # Skip echo/execute of any lines before the desired start line or empty line
  if [[ $LINE_NUMBER -lt $START_WITH_LINE_NUMBER ]] || [[ "${command}" == "" ]]; then
    continue
  fi

  if [[ "${command}" == "" ]]; then
    continue
  elif [[ "${command}" == "@_ECHO_ON" ]]; then
    ECHO=on
    continue
  elif [[ "${command}" == "@_ECHO_OFF" ]]; then
    ECHO=off
    continue
#  elif [[ "${command}" =~ ^#.* ]] || [[ "${command}" =~ ^@#.* ]]; then
#    continue
  fi

  if [[ $ECHO == "on" ]]; then
    printf "\n$BOLD$COLOR\$$RESET "

#    read -sp "" $move </dev/tty   # wait for user input before echoing command
# changed this in favor of reading and executing a sequence of commands
# type return to resume script execution
    read -sp "" move </dev/tty
    while [[ $move != "" ]]; do
      echo $move | pv -qL 10

      eval $move
      printf "\n$BOLD$COLOR\$$RESET "
      read -sp "" move </dev/tty
    done

    printf "$BOLD$COLOR${command}$RESET" | pv -qL 10
    read -sp "" $move </dev/tty   # wait for user input before executing command
    echo ""
  fi
  # execute command
  eval $command
done < $COMMANDS_FILE









