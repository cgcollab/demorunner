#!/bin/bash
#  demorunner.sh
#
#
#  Created by Maria Gabriella Brodi and Cora Iberkleid on 3/28/20.

COMMANDS_FILE="${1}"          # required
START_WITH_LINE_NUMBER="${2}" # optional
START_WITH_LINE_NUMBER="${START_WITH_LINE_NUMBER:-1}" # default to 1 if not provided

RESET_FONT="\033[0m"
BOLD="\033[1m"
YELLOW="\033[38;5;11m"
BLUE="\033[0;34m"
RED="\033[0;31m"
WHITE="\033[38;5;15m"
ECHO=on

# Set color
if [[ $DEMO_COLOR == "blue" ]]; then
  SET_FONT="${BLUE}${BOLD}"
elif [[ $DEMO_COLOR == "white" ]]; then
  SET_FONT="${WHITE}${BOLD}"
else
  SET_FONT="${YELLOW}${BOLD}"
fi

# Set typing delay
DEMO_DELAY=${DEMO_DELAY:-15}


usage_instructions() {
  printf "${RESET_FONT}"
  echo
  echo "This utility enables the simulation of 'live typing' for command-line driven demos by echoing and executing"
  echo "a list of commands that you provide in a 'commands file'."
  echo
  echo "Usage:"
  echo "source ./demorunner.sh (commands-file) [start-with-line-number]"
  echo
  echo "Command-line arguments:"
  echo "  commands-file           - Name of the file with the list of commands to execute. Required."
  echo "  start-with-line-number  - Line number in the commands file at which to begin execution. Optional. Default is 1."
  echo "                            #_ECHO_ON & #_ECHO_OFF commands above the starting line will still be respected, but"
  echo "                            other lines will be ignored."
  echo
  echo "The following flags can be used in the commands file:"
  echo "  #_ECHO_ON   - Turns on echoing and execution of subsequent commands. Must be placed in its own line."
  echo "                When #_ECHO_ON is enabled, user must press the Return key once to echo the next command, and again"
  echo "                to execute it. This is the default mode."
  echo "  #_ECHO_OFF  - Turns off echoing of subsequent commands. Commands will be executed immediately, without user input."
  echo "                Must be placed in its own line."
  echo "  #_ECHO_#    - Strips tag and echoes command starting from #. Must be placed at the beginning of the line."
  echo
  echo "Otherwise, lines starting with # will be ignored."
  echo
  echo "The following environment variables can be used to modify the behavior of the script:"
  echo "  DEMO_COLOR  - May be yellow, blue, or white. Default is yellow."
  echo "  DEMO_DELAY  - Controls the rate of the echoing of commands to simulate live typing. Default is 10."
  echo "                Set to 0 to disable rate-limiting. Increase the setting to make typing appear faster."
  echo
  echo "During execution of your commands file, you may also type a custom command at any time. Once your custom command is"
  echo "executed, press Return at the next empty prompt to continue with the next command from the commands file."
  echo
  echo "--- Known issues/To-do List:"
  echo
  echo "- Up/Down/Left/Right arrows have no effect."
  echo "- Tab/autocompletion does not work."
  echo
}

# If the 'commands file' does not exist, print error and usage instructions
# If a 'start with line number' argument was provided and it is not a number, print error and usage instructions
ERROR=""
if [ $# -eq 0 ] || [[ ${1} =~ -h|--help ]]; then
  usage_instructions
  kill -INT $$
elif [ $# -gt 2 ]; then
  ERROR="Unexpected number of input arguments: expecting 1 or 2 (got $#)"
elif [ ! -f "${COMMANDS_FILE}" ]; then
  ERROR="File does not exist (${COMMANDS_FILE})"
elif { [ $# -eq 2 ] && ! [[ "${START_WITH_LINE_NUMBER}" =~ ^[0-9]+$ ]]; }; then
  ERROR="Second argument must be an integer (got ${START_WITH_LINE_NUMBER})"
fi
if [[ ${ERROR} != "" ]]; then
  printf "${RED}ERROR: ${ERROR}\n"
  usage_instructions
  kill -INT $$
else
  echo "Executing commands in file ${COMMANDS_FILE} starting at line ${START_WITH_LINE_NUMBER}"
fi

# Set terminal tab name to the file name minus the extension
tabname="$(basename -- ${COMMANDS_FILE})"
printf "\e]1;%s\a" "${tabname%.*}"

# Function to process additional user input at runtime
get_user_input() {
  temp_command=${1}
  while IFS= read -srn 1 next_char ; do
    # If user hit enter/return, exit the loop
    if [ "${next_char}" = "" ]; then
      break
    fi
    # If user hit backspace/delete, remove the last character
    if [ "${next_char}" = $'\177' ]; then
      next_char=""
      # If temp_command is not empty, delete last char from temp_command and from terminal
      if [ ${#temp_command} -gt 0 ]; then
        printf "\b \b" >>/dev/tty
        temp_command=${temp_command%?} # remove the last char
      fi
    fi
    # Detect escape sequences, capture if user hit arrow key
    arrow=""
    if [ "${next_char}" = $'\E' ]; then # =$'\E' or =$'\x1b'
      read -srn1 next_char
      if [ "${next_char}" = $'[' ]; then
        read -srn1 next_char
        if [ "${next_char}" = 'A' ]; then
          arrow=up
        elif [ "${next_char}" = 'B' ]; then
          arrow=down
        elif [ "${next_char}" = 'C' ]; then
          arrow=right
        elif [ "${next_char}" = 'D' ]; then
          arrow=left
        else
          printf "${RED}ERROR: ARROW KEY DETECTED - DIRECTION UNKNOWN: ${next_char}${ERROR}\n" >>/dev/tty
        fi
      else
        printf "${RED}ERROR: ESCAPE KEY DETECTED FOLLOWED BY UNRECOGNIZED CHARACTER: ${next_char}${ERROR}\n" >>/dev/tty
      fi
      next_char=""
    fi
    # TODO Handle case where user input is an arrow (currently ignored/no-op)
    # Echo the next_char to the terminal and append temp_command
    printf "${next_char}" >>/dev/tty
    temp_command=${temp_command}${next_char}
  done
  echo "${temp_command}"
}

# Make sure file ends with newline so last
# command is captured in array in next step
c=`tail -c 1 $1`
if [ "$c" != "" ]; then echo "" >> $1; fi

# read all the lines into an array (preserve empty lines so array length matches number
# of lines in commands file (important for accuracy of start-from-line-number argument)
COMMAND_LINES=( )
while IFS= read -r line; do
  #TODO Make sure the following line properly trims whitespaces
  #line="$(echo -e "${line}" | tr -d '[:space:]')"
  COMMAND_LINES+=( "$line" )
done < "${COMMANDS_FILE}"

# Execute commands in array. Allow dynamic input as well.
((LINE_NUMBER=1))
for command in "${COMMAND_LINES[@]}"
do
  # Always check for desired state of ECHO setting
  # Skip lines that start with #, empty lines, and lines before desired start line
  if [[ "${command}" == "#_ECHO_ON" ]]; then
    ECHO=on
    ((LINE_NUMBER=LINE_NUMBER+1))
    continue
  elif [[ "${command}" == "#_ECHO_OFF" ]]; then
    ECHO=off
    ((LINE_NUMBER=LINE_NUMBER+1))
    continue
  elif [[ "${command}" == "" ]] || [[ $LINE_NUMBER -lt $START_WITH_LINE_NUMBER ]]; then
    ((LINE_NUMBER=LINE_NUMBER+1))
    continue
  elif [[ "${command}" =~ ^#_ECHO_#.* ]]; then
    # If line starts with #_ECHO_# tag, remove characters before the #
    command="${command:7}"
    # Process this line - do not "continue"
  elif [[ "${command}" =~ ^#.* ]]; then
    ((LINE_NUMBER=LINE_NUMBER+1))
    continue
  fi
  # If ECHO is off, just execute the command
  if [[ $ECHO == "off" ]]; then
    printf "${RESET_FONT}"
    eval "${command}"
    ((LINE_NUMBER=LINE_NUMBER+1))
    continue
  fi
  # ECHO is on
  # Before echoing the next command, give the user an opportunity to type in one or more custom commands.
  # If they do, execute these first.
  # When the user simply clicks enter/return, echo the next command from the file.
  # The user can then click enter/return once again to execute the command from the file.
  while ( : ); do
    printf "\n${SET_FONT}\$ "
    custom_command=$(get_user_input "")
    # If user entered a custom command, execute it
    if [[ "${custom_command}" != "" ]]; then
      echo
      printf "${RESET_FONT}"
      eval "${custom_command}"
    else
      break
    fi
  done

  # Process command from file
  printf "${SET_FONT}${command}" | pv -qL "${DEMO_DELAY}"
  # Wait for user to hit return/enter before executing. Allow user to delete and change the command as well.
  command=$(get_user_input "${command}")
  echo
  printf "${RESET_FONT}"
  eval "${command}"
  ((LINE_NUMBER=LINE_NUMBER+1))
done

