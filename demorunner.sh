#!/bin/bash --login
# shellcheck shell=bash disable=SC1090,SC2164,SC1091
shopt -s expand_aliases

#  demorunner.sh
#
#  @author Maria Gabriella Brodi
#  @author Cora Iberkleid

COMMANDS_FILE="${1}"          # required
START_WITH_LINE_NUMBER="${2}" # optional
START_WITH_LINE_NUMBER="${START_WITH_LINE_NUMBER:-1}" # default to 1 if not provided

RESET_FONT="\033[0m"
BOLD="\033[1m"
YELLOW="\033[38;5;11m"
BLUE="\033[0;34m"
RED="\033[0;31m"
WHITE="\033[38;5;15m"
BLACK="\033[0;30m"
ECHO=on

# Set color
if [[ $DEMO_COLOR == "blue" ]]; then
  SET_FONT="${BLUE}${BOLD}"
elif [[ $DEMO_COLOR == "white" ]]; then
  SET_FONT="${WHITE}${BOLD}"
elif [[ $DEMO_COLOR == "black" ]]; then
  SET_FONT="${BLACK}${BOLD}"
else
  SET_FONT="${YELLOW}${BOLD}"
fi

# Set typing delay
DEMO_DELAY=${DEMO_DELAY:-15}

declare -a CMD_HISTORY=()

usage_instructions() {
  printf "%b" "${RESET_FONT}" # %b makes printf interpret escape (e.g. \n or color codes)
  echo
  echo "This utility enables the simulation of 'live typing' for command-line driven demos by echoing and executing"
  echo "a list of commands that you provide in a 'commands file'."
  echo
  echo "Usage:"
  echo "  ./demorunner.sh <commands-file> [start-with-line-number]"
  echo "  (Run directly, not with 'source', to prevent mixing its environment with your current shell.)"
  echo
  echo "Command-line arguments:"
  echo "  commands-file           - Name of the file with the list of commands to execute. Required."
  echo "  start-with-line-number  - Line number in the commands file at which to begin execution. Optional. Default is 1."
  echo "                            The most recent #_ECHO_ON or #_ECHO_OFF flag above this line will still be respected."
  echo
  echo "The following flags can be used in the commands file:"
  echo "  #_ECHO_ON   - Enables interactive echoing; subsequent commands are shown and executed one by one."
  echo "  #_ECHO_OFF  - Disables interactive echoing; subsequent commands are executed silently (no prompts or typing)."
  echo "                Note: command output still appears normally unless redirected (e.g., '> /dev/null')."
  echo "  #_ECHO_#    - Strips tag and echoes the rest of the line as a comment (prefixed with #)."
  echo "  #_ECHO_E_#  - Same as #_ECHO_#, but evaluates variables before echoing the comment."
  echo
  echo "Otherwise, lines starting with # or containing only whitespace will be ignored (as in a normal shell script)."
  echo
  echo "Environment variables:"
  echo "  DEMO_COLOR  - Sets the color of the prompt and the displayed command."
  echo "                May be yellow, blue, white, or black. Default is yellow."
  echo "  DEMO_DELAY  - Controls the simulated typing speed. Default is 15."
  echo "                Set to 0 to disable rate-limiting; increase to make typing appear faster."
  echo
  echo "Interactive features:"
  echo "  - When #_ECHO_ON is enabled, press Return once to display the next command, and again to execute it."
  echo "  - Ad-hoc typing: at the prompt, enter any command; press Return on an empty line to resume scripted commands."
  echo "  - Up/Down arrows: browse command history (does not include commands executed silently while #_ECHO_OFF is active)."
  echo "  - Left/Right arrows: move the cursor for in-line editing."
  echo
  echo "Known limitations:"
  echo "  - For ad-hoc commands, escape sequences and control characters other than arrow keys, Backspace, and Return are currently ignored (e.g., Tab, Ctrl+L)."
  echo "  - Tab autocompletion is currently not supported."
  echo
}

# Validation
ERROR=""
if [ $# -eq 0 ] || [[ ${1} == "-h" ]] || [[ ${1} == "--help" ]]; then
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
  printf "%b" "${RED}ERROR: ${ERROR}\n"
  usage_instructions
  kill -INT $$
else
  echo "Executing commands in file ${COMMANDS_FILE} starting at line ${START_WITH_LINE_NUMBER}"
fi

# Set terminal tab name
tabname="$(basename -- ${COMMANDS_FILE})"
printf "\e]1;%s\a" "${tabname%.*}"

# Helper function used by get_user_input() to support cursor moves (arrow keystrokes, backspaces, in-line editing).
# Refreshes the visible prompt ("$ ") and current command after each cursor move.
_redraw_line() {
  local prompt="$1"
  local buf="$2"
  local cursor="$3"
  printf "\r\033[K" >>/dev/tty
  printf "%b%b" "$prompt" "$buf" >>/dev/tty
  local tail=$(( ${#buf} - cursor ))
  if (( tail > 0 )); then
    printf "\033[%dD" "$tail" >>/dev/tty
  fi
}

# Function to process user input with arrow support + history
# Usage: get_user_input "initial_text"
#
# Two contexts:
#  1) User types an ad-hoc command at an empty prompt - initial_text is empty.
#  2) User edits a command echoed from the commands file - initial_text is the original command.
get_user_input() {
  local temp_command="${1}"
  local prompt="${PROMPT_STR:-$ }"

  local cursor=${#temp_command}
  local history_index=${#CMD_HISTORY[@]}
  local history_in_progress=""

  # If initial_text is provided, don't echo it here,
  # since it was already shown during the simulated typing animation.
  if [[ -n "$temp_command" ]]; then
    :
  end_if_comment_guard=true
  fi

  while IFS= read -srn1 next_char ; do
    # Return (\n) ends the loop
    if [[ -z "$next_char" ]]; then
      break
    fi

    # Handle backspace
    if [[ "$next_char" == $'\177' ]]; then
      if (( cursor > 0 )); then
        temp_command="${temp_command:0:cursor-1}${temp_command:cursor}"
        ((cursor--))
        _redraw_line "$prompt" "$temp_command" "$cursor"
      fi
      continue
    fi

    # Handle arrow keys
    # Any other escape sequences are currently ignored
    if [[ "$next_char" == $'\E' ]]; then
      read -srn1 next_char
      if [[ "$next_char" == "[" ]]; then
        read -srn1 next_char
        case "$next_char" in
          A)  # Up (recall previous command)
              if (( ${#CMD_HISTORY[@]} > 0 )); then
                if (( history_index == ${#CMD_HISTORY[@]} )); then
                  history_in_progress="$temp_command"
                fi
                if (( history_index > 0 )); then
                  ((history_index--))
                  temp_command="${CMD_HISTORY[$history_index]}"
                  cursor=${#temp_command}
                  _redraw_line "$prompt" "$temp_command" "$cursor"
                fi
              fi ;;
          B)  # Down (move forward in history)
              if (( ${#CMD_HISTORY[@]} > 0 )); then
                if (( history_index < ${#CMD_HISTORY[@]} )); then
                  ((history_index++))
                  if (( history_index == ${#CMD_HISTORY[@]} )); then
                    temp_command="$history_in_progress"
                  else
                    temp_command="${CMD_HISTORY[$history_index]}"
                  fi
                  cursor=${#temp_command}
                  _redraw_line "$prompt" "$temp_command" "$cursor"
                fi
              fi ;;
          C)  # Right (move cursor right)
              if (( cursor < ${#temp_command} )); then
                ((cursor++))
                printf "\033[1C" >>/dev/tty
              fi ;;
          D)  # Left (move cursor left)
              if (( cursor > 0 )); then
                ((cursor--))
                printf "\033[1D" >>/dev/tty
              fi ;;
        esac
      fi
      continue
    fi

    # Handle normal typed input (letters, numbers, punctuation, spaces)
    # Tab, Ctrl+L, and other control keys are currently ignored.
    if [[ "$next_char" =~ [[:print:]] ]]; then
      temp_command="${temp_command:0:cursor}${next_char}${temp_command:cursor}"
      ((cursor++))
      _redraw_line "$prompt" "$temp_command" "$cursor"
      continue
    fi
  done

  echo "${temp_command}"
}

# Make sure file ends with newline so last
# command is captured in array in next step
c=`tail -c 1 $1`
if [ "$c" != "" ]; then echo "" >> $1; fi

# Read all the lines into an array (preserve empty lines so the array length
# matches the number of lines in the commands file — important for accuracy of
# the start-with-line-number argument)
COMMAND_LINES=( )
while IFS= read -r line; do
  # NOTE: We intentionally do NOT trim whitespace and we preserve empty lines
  # to keep line numbers aligned with the source file.
  COMMAND_LINES+=( "$line" )
done < "${COMMANDS_FILE}"

# Execute commands
((LINE_NUMBER=1))
for command in "${COMMAND_LINES[@]}"
do
  # Handle control flags
  if [[ "${command}" == "#_ECHO_ON" ]]; then
    ECHO=on
    ((LINE_NUMBER++))
    continue
  elif [[ "${command}" == "#_ECHO_OFF" ]]; then
    ECHO=off
    ((LINE_NUMBER++))
    continue
  elif [[ -z "${command//[[:space:]]/}" ]] || [[ $LINE_NUMBER -lt $START_WITH_LINE_NUMBER ]]; then
    # Skip blank or whitespace-only lines — used for readability in commands file only.
    # Also skip lines before the specified start point.
    ((LINE_NUMBER++))
    continue
  elif [[ "${command}" =~ ^#_ECHO_#.* ]]; then
    # If line starts with #_ECHO_# tag, remove characters before the #
    command="${command:7}"
    # Process this line - do not "continue"
  elif [[ "${command}" =~ ^#_ECHO_E_#.* ]]; then
    # If line starts with #_ECHO_E_# tag, remove characters before the #, expand vars after the #
    raw=${command:10}
    expanded_cmd=$(eval "printf '%s\n' \"$raw\"")
    command="#$expanded_cmd"
    # Process this line - do not "continue"
  elif [[ "${command}" =~ ^#.* ]]; then
    ((LINE_NUMBER++))
    continue
  fi

  # When ECHO_OFF is active, execute command immediately (non-interactively);
  # output still appears unless explicitly redirected by the command itself.
  if [[ $ECHO == "off" ]]; then
    printf "%b" "${RESET_FONT}"
    eval "${command}"
    # Skip adding these to command history — user never saw them interactively
    ((LINE_NUMBER++))
    continue
  fi

  # When ECHO_ON is active, let user optionally run ad-hoc commands before continuing
  # This section pauses execution, allowing user experimentation at the demo shell.
  while :; do
    printf "%b" "\n" >>/dev/tty
    PROMPT_STR="${SET_FONT}$ "
    printf "%b" "${PROMPT_STR}" >>/dev/tty
    custom_command=$(get_user_input "")
    # If user entered a custom command, execute it
    if [[ "${custom_command}" != "" ]]; then
      echo
      printf "%b" "${RESET_FONT}"
      eval "${custom_command}"
      CMD_HISTORY+=("${custom_command}")
    else
      break
    fi
  done

  # Simulate typing of next demo command, then pause for user to edit or confirm before execution
  printf "%b" "${SET_FONT}"
  printf "%s" "${command}" | pv -qL "${DEMO_DELAY}"
  PROMPT_STR=""
  edited=$(get_user_input "${command}")
  echo
  printf "%b" "${RESET_FONT}"
  eval "${edited}"
  CMD_HISTORY+=("${edited}")
  ((LINE_NUMBER++))
done

