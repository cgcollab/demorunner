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
  echo "Commands file features:"
  echo "  The following flags can be used in the commands file:"
  echo "    #_ECHO_ON   - Enables interactive echoing; subsequent commands are shown and executed one by one."
  echo "    #_ECHO_OFF  - Disables interactive echoing; subsequent commands are executed silently (no prompts or typing)."
  echo "                  Note: command output still appears normally unless redirected (e.g., '> /dev/null')."
  echo "    #_ECHO_#    - Strips tag and echoes the rest of the line as a comment (prefixed with #)."
  echo "    #_ECHO_E_#  - Same as #_ECHO_#, but evaluates variables before echoing the comment."
  echo
  echo "  Multiline commands are supported:"
  echo "    - Backslash continuation (\\)"
  echo "    - Unclosed quotes (single or double)"
  echo "    - Heredocs (<< EOF, << 'EOF', << \"EOF\")"
  echo "    - Block constructs (if/fi, for/while/done, case/esac, function/{})"
  echo
  echo "  Otherwise, lines starting with # or containing only whitespace will be ignored (as in a normal shell script)."
  echo
  echo "Interactive features:"
  echo "  - When #_ECHO_ON is enabled, press Return once to display the next command, and again to execute it."
  echo "  - Ad-hoc typing: at the prompt, enter any command; press Return on an empty line to resume scripted commands."
  echo "  - Up/Down arrows: browse command history (does not include commands executed silently while #_ECHO_OFF is active)."
  echo "  - Left/Right arrows: move the cursor for in-line editing."
  echo
  echo "Environment variables:"
  echo "  DEMO_COLOR  - Sets the color of the prompt and the displayed command."
  echo "                May be yellow, blue, white, or black. Default is yellow."
  echo "  DEMO_DELAY  - Controls the simulated typing speed. Default is 15."
  echo "                Set to 0 to disable rate-limiting; increase to make typing appear faster."
  echo
  echo "Known limitations:"
  echo "  - For multi-line commands, editing is not supported (left arrow and Backspace are disabled)."
  echo "  - For ad-hoc commands, escape sequences and control characters other than arrow keys, Backspace, and Return are ignored (e.g., Tab, Ctrl+L)."
  echo "  - Tab autocompletion is not supported."
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

# Helper function to display multiline commands from history
# Clears previous lines and displays the multiline command properly
_redraw_multiline() {
  local prompt="$1"
  local buf="$2"
  local cursor="$3"
  printf "\r\033[K" >>/dev/tty
  printf "%b" "$prompt" >>/dev/tty
  local first_line=1
  while IFS= read -r line || [[ -n "$line" ]]; do
    if (( first_line )); then
      printf "%s" "$line" >>/dev/tty
      first_line=0
    else
      printf "\n%s" "$line" >>/dev/tty
    fi
  done <<< "$buf"
}

# Helper to count how many terminal lines are needed to display the buffer
_count_display_lines() {
  local buf="$1"
  local newline_count=$(echo -n "$buf" | tr -cd '\n' | wc -c | tr -d ' ')
  echo $((newline_count + 1))
}

# Helper to clear the currently displayed command (single or multiline)
_clear_displayed_lines() {
  local lines="$1"
  if (( lines <= 0 )); then
    return
  fi
  # Move to the first line of the block (top)
  local up=$((lines - 1))
  while [ $up -gt 0 ]; do
    printf "\033[1A" >>/dev/tty
    ((up--))
  done

  # Clear from top to bottom, staying within the block
  local i=1
  printf "\r\033[K" >>/dev/tty
  while [ $i -lt $lines ]; do
    printf "\033[1B\r\033[K" >>/dev/tty
    ((i++))
  done

  # Return cursor to the top of the cleared block so redraw starts in place
  local back_up=$((lines - 1))
  while [ $back_up -gt 0 ]; do
    printf "\033[1A" >>/dev/tty
    ((back_up--))
  done
}

# Wrapper that chooses the correct redraw strategy based on the buffer content.
# Returns the number of terminal lines used after redraw (1 for single-line).
_render_input_state() {
  local prompt="$1"
  local buf="$2"
  local cursor="$3"
  local current_lines="${4:-1}"

  if [[ "$buf" =~ $'\n' ]]; then
    _clear_displayed_lines "$current_lines"
    _redraw_multiline "$prompt" "$buf" "$cursor"
    _count_display_lines "$buf"
  else
    if (( current_lines > 1 )); then
      _clear_displayed_lines "$current_lines"
    fi
    _redraw_line "$prompt" "$buf" "$cursor"
    echo 1
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
  local displayed_lines=1
  local newline_appended_since_input=0

  if [[ "$temp_command" =~ $'\n' ]]; then
    displayed_lines=$(_count_display_lines "$temp_command")
  fi

  # If initial_text is provided, don't echo it here,
  # since it was already shown during the simulated typing animation.
  if [[ -n "$temp_command" ]]; then
    :
  end_if_comment_guard=true
  fi

  while IFS= read -srn1 next_char ; do
    # Ignore carriage return characters (they arrive during CRLF pastes)
    if [[ "$next_char" == $'\r' ]]; then
      continue
    fi
    # Handle newline (Enter) - either execute or keep building multiline command
    if [[ -z "$next_char" ]]; then
      local buffer_repr="${temp_command//$'\n'/\\n}"
      # Peek immediately to see if more characters are waiting (paste). If so, treat
      # this newline as literal, append it, and process the queued char next loop.
      local lookahead=""
      if IFS= read -srn1 -t 0 lookahead ; then
        if [[ "$lookahead" != $'\r' ]]; then
          temp_command="${temp_command:0:cursor}"$'\n'"${temp_command:cursor}"
          cursor=${#temp_command}
          displayed_lines=$(_render_input_state "$prompt" "$temp_command" "$cursor" "$displayed_lines")
          newline_appended_since_input=0
        fi
        next_char="$lookahead"
        continue
      fi

      # No more input waiting — decide whether to execute or continue the multiline.
      if [[ -z "${temp_command//[[:space:]]/}" ]]; then
        break
      fi
      if is_command_complete "$temp_command"; then
        break
      fi

      if (( newline_appended_since_input == 0 )); then
        break
      fi

      temp_command="${temp_command:0:cursor}"$'\n'"${temp_command:cursor}"
      cursor=${#temp_command}
      displayed_lines=$(_render_input_state "$prompt" "$temp_command" "$cursor" "$displayed_lines")
      newline_appended_since_input=1
      continue
    fi

    # Handle Ctrl+C (ASCII 3) - abort current input and reset prompt
    if [[ "$next_char" == $'\003' ]]; then
      _clear_displayed_lines "$displayed_lines"
      printf "^C\n" >>/dev/tty
      temp_command=""
      cursor=0
      displayed_lines=1
      newline_appended_since_input=0
      printf "%b" "$prompt" >>/dev/tty
      continue
    fi

    # Handle backspace
    if [[ "$next_char" == $'\177' ]]; then
      # Disable backspace for multiline commands (too complex to handle properly)
      if [[ "$temp_command" =~ $'\n' ]]; then
        continue
      fi
      if (( cursor > 0 )); then
        temp_command="${temp_command:0:cursor-1}${temp_command:cursor}"
        ((cursor--))
        displayed_lines=$(_render_input_state "$prompt" "$temp_command" "$cursor" "$displayed_lines")
        newline_appended_since_input=0
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
                  _clear_displayed_lines "$displayed_lines"
                  ((history_index--))
                  temp_command="${CMD_HISTORY[$history_index]}"
                  cursor=${#temp_command}
                  displayed_lines=$(_render_input_state "$prompt" "$temp_command" "$cursor" 1)
                  newline_appended_since_input=0
                fi
              fi ;;
          B)  # Down (move forward in history)
              if (( ${#CMD_HISTORY[@]} > 0 )); then
                if (( history_index < ${#CMD_HISTORY[@]} )); then
                  _clear_displayed_lines "$displayed_lines"
                  ((history_index++))
                  if (( history_index == ${#CMD_HISTORY[@]} )); then
                    temp_command="$history_in_progress"
                  else
                    temp_command="${CMD_HISTORY[$history_index]}"
                  fi
                  cursor=${#temp_command}
                  displayed_lines=$(_render_input_state "$prompt" "$temp_command" "$cursor" 1)
                  newline_appended_since_input=0
                fi
              fi ;;
          C)  # Right (move cursor right)
              if (( cursor < ${#temp_command} )); then
                ((cursor++))
                printf "\033[1C" >>/dev/tty
              fi ;;
          D)  # Left (move cursor left)
              # Disable left arrow for multiline commands (too complex to handle properly)
              if [[ "$temp_command" =~ $'\n' ]]; then
                continue
              fi
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
      displayed_lines=$(_render_input_state "$prompt" "$temp_command" "$cursor" "$displayed_lines")
      newline_appended_since_input=0
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

# Function to check if a command line is complete (not continued on next line)
# Returns 0 if complete, 1 if incomplete
# Helper function to strip inline comments from a single line
# Returns the line with comments removed (everything after # outside quotes)
_strip_inline_comment_from_line() {
  local line="$1"
  local result=""
  local in_single_q=0
  local in_double_q=0
  local i=0
  while [ $i -lt ${#line} ]; do
    local ch="${line:$i:1}"
    local is_esc=0
    if [ $i -gt 0 ]; then
      local prev_ch="${line:$((i-1)):1}"
      if [[ "$prev_ch" == "\\" ]]; then
        is_esc=1
      fi
    fi
    if [[ $is_esc -eq 0 ]]; then
      if [[ "$ch" == "'" ]] && [[ $in_double_q -eq 0 ]]; then
        in_single_q=$((1 - in_single_q))
        result="${result}${ch}"
      elif [[ "$ch" == "\"" ]] && [[ $in_single_q -eq 0 ]]; then
        in_double_q=$((1 - in_double_q))
        result="${result}${ch}"
      elif [[ "$ch" == "#" ]] && [[ $in_single_q -eq 0 ]] && [[ $in_double_q -eq 0 ]]; then
        break
      else
        result="${result}${ch}"
      fi
    else
      result="${result}${ch}"
    fi
    ((i++))
  done
  echo "$result"
}

# Helper function to strip comments from a full command (removes inline comments and comment-only lines)
_strip_comments_from_command() {
  local cmd="$1"
  local result=""
  local first_line=1
  while IFS= read -r line || [ -n "$line" ]; do
    local line_no_comment=$(_strip_inline_comment_from_line "$line")
    # Skip comment-only lines entirely
    if [[ -z "${line_no_comment//[[:space:]]/}" ]] && [[ "${line}" =~ ^[[:space:]]*# ]]; then
      continue
    fi
    if [[ $first_line -eq 1 ]]; then
      result="${line_no_comment}"
      first_line=0
    else
      result="${result}"$'\n'"${line_no_comment}"
    fi
  done <<< "$cmd"
  echo "$result"
}

is_command_complete() {
  local cmd="$1"
  local trimmed="${cmd%"${cmd##*[![:space:]]}"}"  # Remove trailing whitespace
  
  # Check for backslash/pipe continuation on the last line
  # Need to remove inline comments first to check properly
  # Get the last non-empty line (in case command ends with empty line)
  local last_line=$(echo "$cmd" | grep -v '^[[:space:]]*$' | tail -n 1)
  if [[ -z "$last_line" ]]; then
    # If all lines are empty, get the actual last line
    last_line=$(echo "$cmd" | tail -n 1)
  fi
  # Use helper function to strip inline comments
  local last_line_no_comment=$(_strip_inline_comment_from_line "$last_line")
  local last_line_no_comment_trimmed="${last_line_no_comment%"${last_line_no_comment##*[![:space:]]}"}"
  
  
  # Check for backslash continuation (most common case)
  if [[ "${last_line_no_comment_trimmed}" =~ \\$ ]]; then
    return 1  # Incomplete - has backslash continuation
  fi
  
  # Check for pipe continuation (| at end of line indicates command continues)
  if [[ "${last_line_no_comment_trimmed}" =~ \|$ ]]; then
    return 1  # Incomplete - has pipe continuation
  fi
  
  # Check for incomplete heredoc/EOF FIRST (before quote detection)
  # Handle both quoted and unquoted delimiters: << EOF, << 'EOF', << "EOF", etc.
  # Exclude <<< (here-string) which is a single-line operator
  # Skip heredoc check if line contains <<< (here-string operator)
  if ! echo "$cmd" | grep -qE '<<<'; then
    if echo "$cmd" | grep -qE '<<-?\s*['\''"]?[A-Za-z_][A-Za-z0-9_]*['\''"]?'; then
      # Extract heredoc delimiters (with or without quotes)
      # First get all heredoc patterns, then extract just the delimiter name
      local heredoc_patterns=$(echo "$cmd" | grep -oE '<<-?\s*['\''"]?[A-Za-z_][A-Za-z0-9_]*['\''"]?')
    local heredoc_delimiters=""
    for pattern in $heredoc_patterns; do
      # Extract just the delimiter name (remove <<, optional -, spaces, and quotes)
      # Use multiple sed commands to handle quotes properly
      local delimiter=$(echo "$pattern" | sed 's/<<-*[[:space:]]*//' | sed "s/^['\"]//" | sed "s/['\"]\$//")
      heredoc_delimiters="$heredoc_delimiters $delimiter"
    done
    heredoc_delimiters="${heredoc_delimiters# }"  # Remove leading space
    
    local last_line=$(echo "$cmd" | tail -n 1)
    local last_line_trimmed="${last_line#"${last_line%%[![:space:]]*}"}"  # Remove leading whitespace
    local found_delimiter=0
    for delimiter in $heredoc_delimiters; do
      # Check if last line matches the delimiter (with or without quotes)
      if [[ "$last_line_trimmed" == "$delimiter" ]] || \
         [[ "$last_line_trimmed" == "'$delimiter'" ]] || \
         [[ "$last_line_trimmed" == "\"$delimiter\"" ]]; then
        found_delimiter=1
        break
      fi
    done
    if [[ $found_delimiter -eq 0 ]]; then
      return 1  # Incomplete - heredoc not closed
    fi
    fi  # End of heredoc pattern check
  fi  # End of <<< exclusion check
  
  # Check for unclosed quotes by counting unescaped quotes
  # First, mask out quotes that are part of heredoc delimiters (<< 'EOF' or << "EOF")
  local masked_cmd="$cmd"
  # Replace << 'DELIMITER' and << "DELIMITER" patterns with << DELIMITER (remove quotes)
  masked_cmd=$(echo "$masked_cmd" | sed -E "s/<<-?[[:space:]]*['\"]([A-Za-z_][A-Za-z0-9_]*)['\"]/<< \\1/g")
  
  local in_single=0
  local in_double=0
  local i=0
  while [ $i -lt ${#masked_cmd} ]; do
    local char="${masked_cmd:$i:1}"
    local is_escaped=0
    if [ $i -gt 0 ]; then
      local prev_char="${masked_cmd:$((i-1)):1}"
      if [[ "$prev_char" == "\\" ]]; then
        is_escaped=1
      fi
    fi
    
    # Only process if not escaped
    if [[ $is_escaped -eq 0 ]]; then
      if [[ "$char" == "'" ]] && [[ $in_double -eq 0 ]]; then
        # Toggle single quote state
        in_single=$((1 - in_single))
      elif [[ "$char" == "\"" ]] && [[ $in_single -eq 0 ]]; then
        # Toggle double quote state
        in_double=$((1 - in_double))
      fi
    fi
    ((i++))
  done
  
  # If we're inside quotes, command is incomplete
  if [[ $in_single -eq 1 ]] || [[ $in_double -eq 1 ]]; then
    return 1  # Incomplete - unclosed quotes
  fi
  
  # Check for incomplete block constructs
  # First, remove heredoc content, then remove quoted strings, to avoid counting keywords inside them
  # Remove heredoc content: everything between << DELIMITER and DELIMITER (including delimiter line)
  local no_heredoc_cmd=""
  local in_heredoc=0
  local heredoc_delimiter=""
  while IFS= read -r line || [ -n "$line" ]; do
    # Check if this line starts a heredoc
    if echo "$line" | grep -qE '<<-?\s*['\''"]?[A-Za-z_][A-Za-z0-9_]*['\''"]?'; then
      # Extract delimiter
      local heredoc_pattern=$(echo "$line" | grep -oE '<<-?\s*['\''"]?[A-Za-z_][A-Za-z0-9_]*['\''"]?')
      heredoc_delimiter=$(echo "$heredoc_pattern" | sed 's/<<-*[[:space:]]*//' | sed "s/^['\"]//" | sed "s/['\"]\$//")
      in_heredoc=1
      # Include the heredoc start line (it may contain other code)
      if [[ -n "$no_heredoc_cmd" ]]; then
        no_heredoc_cmd="${no_heredoc_cmd}"$'\n'"${line}"
      else
        no_heredoc_cmd="${line}"
      fi
    elif [[ $in_heredoc -eq 1 ]]; then
      # Check if this line is the delimiter (with optional leading whitespace)
      local line_trimmed="${line#"${line%%[![:space:]]*}"}"
      if [[ "$line_trimmed" == "$heredoc_delimiter" ]] || \
         [[ "$line_trimmed" == "'$heredoc_delimiter'" ]] || \
         [[ "$line_trimmed" == "\"$heredoc_delimiter\"" ]]; then
        # End of heredoc - include delimiter line (it may contain other code)
        in_heredoc=0
        heredoc_delimiter=""
        if [[ -n "$no_heredoc_cmd" ]]; then
          no_heredoc_cmd="${no_heredoc_cmd}"$'\n'"${line}"
        else
          no_heredoc_cmd="${line}"
        fi
      fi
      # If still in heredoc, skip this line (it's heredoc content)
    else
      # Not in heredoc - include the line
      if [[ -n "$no_heredoc_cmd" ]]; then
        no_heredoc_cmd="${no_heredoc_cmd}"$'\n'"${line}"
      else
        no_heredoc_cmd="${line}"
      fi
    fi
  done <<< "$cmd"
  
  # Now remove inline comments (everything after # that's not inside quotes)
  # Process line by line to remove inline comments
  local no_inline_comments_cmd=""
  while IFS= read -r line || [ -n "$line" ]; do
    local in_single_q=0
    local in_double_q=0
    local j=0
    local line_without_comment=""
    while [ $j -lt ${#line} ]; do
      local ch="${line:$j:1}"
      local is_esc=0
      if [ $j -gt 0 ]; then
        local prev_ch="${line:$((j-1)):1}"
        if [[ "$prev_ch" == "\\" ]]; then
          is_esc=1
        fi
      fi
      if [[ $is_esc -eq 0 ]]; then
        if [[ "$ch" == "'" ]] && [[ $in_double_q -eq 0 ]]; then
          in_single_q=$((1 - in_single_q))
          line_without_comment="${line_without_comment}${ch}"
        elif [[ "$ch" == "\"" ]] && [[ $in_single_q -eq 0 ]]; then
          in_double_q=$((1 - in_double_q))
          line_without_comment="${line_without_comment}${ch}"
        elif [[ "$ch" == "#" ]] && [[ $in_single_q -eq 0 ]] && [[ $in_double_q -eq 0 ]]; then
          # Found # outside quotes - this starts a comment, stop here
          break
        else
          line_without_comment="${line_without_comment}${ch}"
        fi
      else
        line_without_comment="${line_without_comment}${ch}"
      fi
      ((j++))
    done
    if [[ -n "$no_inline_comments_cmd" ]]; then
      no_inline_comments_cmd="${no_inline_comments_cmd}"$'\n'"${line_without_comment}"
    else
      no_inline_comments_cmd="${line_without_comment}"
    fi
  done <<< "$no_heredoc_cmd"
  
  # Now remove quoted strings from the command (without heredoc content and inline comments)
  # Use masked_cmd logic but on no_inline_comments_cmd
  local masked_no_heredoc="$no_inline_comments_cmd"
  masked_no_heredoc=$(echo "$masked_no_heredoc" | sed -E "s/<<-?[[:space:]]*['\"]([A-Za-z_][A-Za-z0-9_]*)['\"]/<< \\1/g")
  
  local unquoted_cmd=""
  local in_single_quote=0
  local in_double_quote=0
  local i=0
  while [ $i -lt ${#masked_no_heredoc} ]; do
    local char="${masked_no_heredoc:$i:1}"
    local is_escaped=0
    if [ $i -gt 0 ]; then
      local prev_char="${masked_no_heredoc:$((i-1)):1}"
      if [[ "$prev_char" == "\\" ]]; then
        is_escaped=1
      fi
    fi
    
    # Only process if not escaped
    if [[ $is_escaped -eq 0 ]]; then
      if [[ "$char" == "'" ]] && [[ $in_double_quote -eq 0 ]]; then
        # Toggle single quote state - don't include the quote character
        in_single_quote=$((1 - in_single_quote))
      elif [[ "$char" == "\"" ]] && [[ $in_single_quote -eq 0 ]]; then
        # Toggle double quote state - don't include the quote character
        in_double_quote=$((1 - in_double_quote))
      elif [[ $in_single_quote -eq 0 ]] && [[ $in_double_quote -eq 0 ]]; then
        # Not inside quotes - include this character
        unquoted_cmd="${unquoted_cmd}${char}"
      fi
      # If inside quotes, skip this character
    else
      # Escaped character - include it if not in quotes
      if [[ $in_single_quote -eq 0 ]] && [[ $in_double_quote -eq 0 ]]; then
        unquoted_cmd="${unquoted_cmd}${char}"
      fi
    fi
    ((i++))
  done
  
  # Remove comment lines (lines starting with # after optional whitespace) before counting keywords
  # Split by newlines, filter out comment lines, rejoin
  local no_comments_cmd=""
  while IFS= read -r line || [ -n "$line" ]; do
    # Remove leading whitespace to check if line starts with #
    local trimmed_line="${line#"${line%%[![:space:]]*}"}"
    if [[ ! "$trimmed_line" =~ ^# ]]; then
      # Not a comment line - include it
      if [[ -n "$no_comments_cmd" ]]; then
        no_comments_cmd="${no_comments_cmd}"$'\n'"${line}"
      else
        no_comments_cmd="${line}"
      fi
    fi
  done <<< "$unquoted_cmd"
  
  # Now count keywords only in unquoted, non-comment parts
  local if_count=$(echo "$no_comments_cmd" | grep -oE '\bif\b' | wc -l | tr -d ' ')
  local fi_count=$(echo "$no_comments_cmd" | grep -oE '\bfi\b' | wc -l | tr -d ' ')
  local for_count=$(echo "$no_comments_cmd" | grep -oE '\bfor\b' | wc -l | tr -d ' ')
  local while_count=$(echo "$no_comments_cmd" | grep -oE '\bwhile\b' | wc -l | tr -d ' ')
  local do_count=$(echo "$no_comments_cmd" | grep -oE '\bdo\b' | wc -l | tr -d ' ')
  local done_count=$(echo "$no_comments_cmd" | grep -oE '\bdone\b' | wc -l | tr -d ' ')
  local case_count=$(echo "$no_comments_cmd" | grep -oE '\bcase\b' | wc -l | tr -d ' ')
  local esac_count=$(echo "$no_comments_cmd" | grep -oE '\besac\b' | wc -l | tr -d ' ')
  local function_count=$(echo "$no_comments_cmd" | grep -oE '\bfunction\b' | wc -l | tr -d ' ')
  local left_brace_count=$(echo "$no_comments_cmd" | grep -oE '\{' | wc -l | tr -d ' ')
  local right_brace_count=$(echo "$no_comments_cmd" | grep -oE '\}' | wc -l | tr -d ' ')
  
  # Check for unclosed blocks
  if [[ $((if_count - fi_count)) -gt 0 ]] || \
     [[ $((for_count + while_count - done_count)) -gt 0 ]] || \
     [[ $((case_count - esac_count)) -gt 0 ]] || \
     [[ $((function_count + left_brace_count - right_brace_count)) -gt 0 ]]; then
    return 1  # Incomplete - unclosed block
  fi
  
  return 0  # Complete
}

# Execute commands
((LINE_NUMBER=1))
((ARRAY_INDEX=0))
while [ $ARRAY_INDEX -lt ${#COMMAND_LINES[@]} ]; do
  command="${COMMAND_LINES[$ARRAY_INDEX]}"
  first_line_number=$LINE_NUMBER
  display_command=""  # For backslash/pipe-continued commands, preserve original format
  has_backslash_continuation=0
  has_pipe_continuation=0
  
  # Skip empty lines and comments before checking for multi-line
  if [[ -z "${command//[[:space:]]/}" ]] || ([[ "${command}" =~ ^#.* ]] && ! [[ "${command}" =~ ^#_ECHO ]]); then
    ((LINE_NUMBER++))
    ((ARRAY_INDEX++))
    continue
  fi
  
  # Handle control flags (these are always single-line)
  if [[ "${command}" == "#_ECHO_ON" ]] || [[ "${command}" == "#_ECHO_OFF" ]] || \
     [[ "${command}" =~ ^#_ECHO_#.* ]] || [[ "${command}" =~ ^#_ECHO_E_#.* ]]; then
    # Process these normally (they're handled below)
    :
  else
    # Check if first line has backslash or pipe continuation (strip inline comments first)
    first_trimmed="${command%"${command##*[![:space:]]}"}"
    # Remove inline comments from first line to check for continuation
    first_line_no_comment=""
    in_single_q_first=0
    in_double_q_first=0
    i_first=0
    while [ $i_first -lt ${#first_trimmed} ]; do
      ch_first="${first_trimmed:$i_first:1}"
      is_esc_first=0
      if [ $i_first -gt 0 ]; then
        prev_ch_first="${first_trimmed:$((i_first-1)):1}"
        if [[ "$prev_ch_first" == "\\" ]]; then
          is_esc_first=1
        fi
      fi
      if [[ $is_esc_first -eq 0 ]]; then
        if [[ "$ch_first" == "'" ]] && [[ $in_double_q_first -eq 0 ]]; then
          in_single_q_first=$((1 - in_single_q_first))
          first_line_no_comment="${first_line_no_comment}${ch_first}"
        elif [[ "$ch_first" == "\"" ]] && [[ $in_single_q_first -eq 0 ]]; then
          in_double_q_first=$((1 - in_double_q_first))
          first_line_no_comment="${first_line_no_comment}${ch_first}"
        elif [[ "$ch_first" == "#" ]] && [[ $in_single_q_first -eq 0 ]] && [[ $in_double_q_first -eq 0 ]]; then
          break
        else
          first_line_no_comment="${first_line_no_comment}${ch_first}"
        fi
      else
        first_line_no_comment="${first_line_no_comment}${ch_first}"
      fi
      ((i_first++))
    done
    first_line_no_comment_trimmed="${first_line_no_comment%"${first_line_no_comment##*[![:space:]]}"}"
    
    if [[ "${first_line_no_comment_trimmed}" =~ \\$ ]]; then
      has_backslash_continuation=1
      display_command="${command}"  # Preserve original with inline comment for display
    elif [[ "${first_line_no_comment_trimmed}" =~ \|$ ]]; then
      has_pipe_continuation=1
      display_command="${command}"  # Preserve original with inline comment for display
    else
      # Initialize display_command even if first line doesn't have backslash/pipe
      # (backslashes/pipes might appear later in the block)
      display_command="${command}"
    fi
    
    # For regular commands, check if they're complete or need continuation
    comment_after_continuation=0  # Initialize flag for comment skipping
    while ! is_command_complete "$command"; do
      # Reset comment flag at start of each iteration (before getting next line)
      comment_after_continuation=0
      
      ((ARRAY_INDEX++))
      ((LINE_NUMBER++))
      if [ $ARRAY_INDEX -ge ${#COMMAND_LINES[@]} ]; then
        break  # End of file
      fi
      next_line="${COMMAND_LINES[$ARRAY_INDEX]}"
      
      # If we hit a control flag, stop accumulating (trim whitespace for exact match)
      next_line_trimmed="${next_line#"${next_line%%[![:space:]]*}"}"  # Remove leading whitespace
      if [[ "${next_line_trimmed}" == "#_ECHO_ON" ]] || [[ "${next_line_trimmed}" == "#_ECHO_OFF" ]] || \
         [[ "${next_line_trimmed}" =~ ^#_ECHO_#.* ]] || [[ "${next_line_trimmed}" =~ ^#_ECHO_E_#.* ]]; then
        # Set command to the control flag so it gets processed correctly
        # Decrement indices since we already incremented them, and the control flag handler will increment again
        ((ARRAY_INDEX--))
        ((LINE_NUMBER--))
        command="${next_line_trimmed}"
        break
      fi
      
      # Check if we're inside an incomplete block construct
      # This determines whether to include empty lines and comments as part of the block
      # Remove heredoc content, then quoted strings, then comments to avoid counting keywords inside them
      cmd_for_block_check="$command"
      
      # First, remove heredoc content
      no_heredoc_for_block=""
      in_heredoc_block=0
      heredoc_delim_block=""
      while IFS= read -r line || [ -n "$line" ]; do
        if echo "$line" | grep -qE '<<-?\s*['\''"]?[A-Za-z_][A-Za-z0-9_]*['\''"]?'; then
          heredoc_pattern_block=$(echo "$line" | grep -oE '<<-?\s*['\''"]?[A-Za-z_][A-Za-z0-9_]*['\''"]?')
          heredoc_delim_block=$(echo "$heredoc_pattern_block" | sed 's/<<-*[[:space:]]*//' | sed "s/^['\"]//" | sed "s/['\"]\$//")
          in_heredoc_block=1
          if [[ -n "$no_heredoc_for_block" ]]; then
            no_heredoc_for_block="${no_heredoc_for_block}"$'\n'"${line}"
          else
            no_heredoc_for_block="${line}"
          fi
        elif [[ $in_heredoc_block -eq 1 ]]; then
          line_trimmed_block="${line#"${line%%[![:space:]]*}"}"
          if [[ "$line_trimmed_block" == "$heredoc_delim_block" ]] || \
             [[ "$line_trimmed_block" == "'$heredoc_delim_block'" ]] || \
             [[ "$line_trimmed_block" == "\"$heredoc_delim_block\"" ]]; then
            in_heredoc_block=0
            heredoc_delim_block=""
            if [[ -n "$no_heredoc_for_block" ]]; then
              no_heredoc_for_block="${no_heredoc_for_block}"$'\n'"${line}"
            else
              no_heredoc_for_block="${line}"
            fi
          fi
        else
          if [[ -n "$no_heredoc_for_block" ]]; then
            no_heredoc_for_block="${no_heredoc_for_block}"$'\n'"${line}"
          else
            no_heredoc_for_block="${line}"
          fi
        fi
      done <<< "$cmd_for_block_check"
      
      # Remove inline comments (everything after # that's not inside quotes)
      no_inline_comments_for_block=""
      while IFS= read -r line || [ -n "$line" ]; do
        in_single_q_line=0
        in_double_q_line=0
        j_line=0
        line_without_comment_block=""
        while [ $j_line -lt ${#line} ]; do
          ch_line="${line:$j_line:1}"
          is_esc_line=0
          if [ $j_line -gt 0 ]; then
            prev_ch_line="${line:$((j_line-1)):1}"
            if [[ "$prev_ch_line" == "\\" ]]; then
              is_esc_line=1
            fi
          fi
          if [[ $is_esc_line -eq 0 ]]; then
            if [[ "$ch_line" == "'" ]] && [[ $in_double_q_line -eq 0 ]]; then
              in_single_q_line=$((1 - in_single_q_line))
              line_without_comment_block="${line_without_comment_block}${ch_line}"
            elif [[ "$ch_line" == "\"" ]] && [[ $in_single_q_line -eq 0 ]]; then
              in_double_q_line=$((1 - in_double_q_line))
              line_without_comment_block="${line_without_comment_block}${ch_line}"
            elif [[ "$ch_line" == "#" ]] && [[ $in_single_q_line -eq 0 ]] && [[ $in_double_q_line -eq 0 ]]; then
              # Found # outside quotes - this starts a comment, stop here
              break
            else
              line_without_comment_block="${line_without_comment_block}${ch_line}"
            fi
          else
            line_without_comment_block="${line_without_comment_block}${ch_line}"
          fi
          ((j_line++))
        done
        if [[ -n "$no_inline_comments_for_block" ]]; then
          no_inline_comments_for_block="${no_inline_comments_for_block}"$'\n'"${line_without_comment_block}"
        else
          no_inline_comments_for_block="${line_without_comment_block}"
        fi
      done <<< "$no_heredoc_for_block"
      
      # Remove heredoc quote patterns
      cmd_for_block_check=$(echo "$no_inline_comments_for_block" | sed -E "s/<<-?[[:space:]]*['\"]([A-Za-z_][A-Za-z0-9_]*)['\"]/<< \\1/g")
      unquoted_for_block=""
      in_single_q=0
      in_double_q=0
      j=0
      while [ $j -lt ${#cmd_for_block_check} ]; do
        ch="${cmd_for_block_check:$j:1}"
        is_esc=0
        if [ $j -gt 0 ]; then
          prev_ch="${cmd_for_block_check:$((j-1)):1}"
          if [[ "$prev_ch" == "\\" ]]; then
            is_esc=1
          fi
        fi
        if [[ $is_esc -eq 0 ]]; then
          if [[ "$ch" == "'" ]] && [[ $in_double_q -eq 0 ]]; then
            in_single_q=$((1 - in_single_q))
          elif [[ "$ch" == "\"" ]] && [[ $in_single_q -eq 0 ]]; then
            in_double_q=$((1 - in_double_q))
          elif [[ $in_single_q -eq 0 ]] && [[ $in_double_q -eq 0 ]]; then
            unquoted_for_block="${unquoted_for_block}${ch}"
          fi
        else
          if [[ $in_single_q -eq 0 ]] && [[ $in_double_q -eq 0 ]]; then
            unquoted_for_block="${unquoted_for_block}${ch}"
          fi
        fi
        ((j++))
      done
      # Remove comment lines before counting keywords
      no_comments_for_block=""
      while IFS= read -r line || [ -n "$line" ]; do
        trimmed_line="${line#"${line%%[![:space:]]*}"}"
        if [[ ! "$trimmed_line" =~ ^# ]]; then
          if [[ -n "$no_comments_for_block" ]]; then
            no_comments_for_block="${no_comments_for_block}"$'\n'"${line}"
          else
            no_comments_for_block="${line}"
          fi
        fi
      done <<< "$unquoted_for_block"
      if_count=$(echo "$no_comments_for_block" | grep -oE '\bif\b' | wc -l | tr -d ' ')
      fi_count=$(echo "$no_comments_for_block" | grep -oE '\bfi\b' | wc -l | tr -d ' ')
      for_count=$(echo "$no_comments_for_block" | grep -oE '\bfor\b' | wc -l | tr -d ' ')
      while_count=$(echo "$no_comments_for_block" | grep -oE '\bwhile\b' | wc -l | tr -d ' ')
      do_count=$(echo "$no_comments_for_block" | grep -oE '\bdo\b' | wc -l | tr -d ' ')
      done_count=$(echo "$no_comments_for_block" | grep -oE '\bdone\b' | wc -l | tr -d ' ')
      case_count=$(echo "$no_comments_for_block" | grep -oE '\bcase\b' | wc -l | tr -d ' ')
      esac_count=$(echo "$no_comments_for_block" | grep -oE '\besac\b' | wc -l | tr -d ' ')
      function_count=$(echo "$no_comments_for_block" | grep -oE '\bfunction\b' | wc -l | tr -d ' ')
      left_brace_count=$(echo "$no_comments_for_block" | grep -oE '\{' | wc -l | tr -d ' ')
      right_brace_count=$(echo "$no_comments_for_block" | grep -oE '\}' | wc -l | tr -d ' ')
      inside_block=0
      if [[ $((if_count - fi_count)) -gt 0 ]] || \
         [[ $((for_count + while_count - done_count)) -gt 0 ]] || \
         [[ $((case_count - esac_count)) -gt 0 ]] || \
         [[ $((function_count + left_brace_count - right_brace_count)) -gt 0 ]]; then
        inside_block=1
      fi
      
      # Check if we're inside unclosed quotes - if so, always continue accumulating
      # Use the same logic as is_command_complete for quote detection
      masked_for_quote_check="$command"
      masked_for_quote_check=$(echo "$masked_for_quote_check" | sed -E "s/<<-?[[:space:]]*['\"]([A-Za-z_][A-Za-z0-9_]*)['\"]/<< \\1/g")
      in_single_quote_check=0
      in_double_quote_check=0
      k=0
      while [ $k -lt ${#masked_for_quote_check} ]; do
        ch_quote="${masked_for_quote_check:$k:1}"
        is_esc_quote=0
        if [ $k -gt 0 ]; then
          prev_ch_quote="${masked_for_quote_check:$((k-1)):1}"
          if [[ "$prev_ch_quote" == "\\" ]]; then
            is_esc_quote=1
          fi
        fi
        if [[ $is_esc_quote -eq 0 ]]; then
          if [[ "$ch_quote" == "'" ]] && [[ $in_double_quote_check -eq 0 ]]; then
            in_single_quote_check=$((1 - in_single_quote_check))
          elif [[ "$ch_quote" == "\"" ]] && [[ $in_single_quote_check -eq 0 ]]; then
            in_double_quote_check=$((1 - in_double_quote_check))
          fi
        fi
        ((k++))
      done
      inside_quotes=0
      if [[ $in_single_quote_check -eq 1 ]] || [[ $in_double_quote_check -eq 1 ]]; then
        inside_quotes=1
      fi
      
      # If we hit an empty line, include it if inside quotes, inside a block, or if command has backslash/pipe continuation
      # Otherwise, empty lines separate commands, so break to let is_command_complete check handle it
      if [[ -z "${next_line//[[:space:]]/}" ]]; then
        # Check the last non-empty line of the command for continuation markers (strip inline comments first)
        last_line_for_empty=$(echo "$command" | grep -v '^[[:space:]]*$' | tail -n 1)
        if [[ -z "$last_line_for_empty" ]]; then
          # If all lines are empty, get the actual last line
          last_line_for_empty=$(echo "$command" | tail -n 1)
        fi
        last_line_trimmed_for_empty="${last_line_for_empty%"${last_line_for_empty##*[![:space:]]}"}"
        # Remove inline comments from the last line
        last_line_no_comment_for_empty=""
        in_single_q_empty=0
        in_double_q_empty=0
        l_empty=0
        while [ $l_empty -lt ${#last_line_trimmed_for_empty} ]; do
          ch_empty="${last_line_trimmed_for_empty:$l_empty:1}"
          is_esc_empty=0
          if [ $l_empty -gt 0 ]; then
            prev_ch_empty="${last_line_trimmed_for_empty:$((l_empty-1)):1}"
            if [[ "$prev_ch_empty" == "\\" ]]; then
              is_esc_empty=1
            fi
          fi
          if [[ $is_esc_empty -eq 0 ]]; then
            if [[ "$ch_empty" == "'" ]] && [[ $in_double_q_empty -eq 0 ]]; then
              in_single_q_empty=$((1 - in_single_q_empty))
              last_line_no_comment_for_empty="${last_line_no_comment_for_empty}${ch_empty}"
            elif [[ "$ch_empty" == "\"" ]] && [[ $in_single_q_empty -eq 0 ]]; then
              in_double_q_empty=$((1 - in_double_q_empty))
              last_line_no_comment_for_empty="${last_line_no_comment_for_empty}${ch_empty}"
            elif [[ "$ch_empty" == "#" ]] && [[ $in_single_q_empty -eq 0 ]] && [[ $in_double_q_empty -eq 0 ]]; then
              break
            else
              last_line_no_comment_for_empty="${last_line_no_comment_for_empty}${ch_empty}"
            fi
          else
            last_line_no_comment_for_empty="${last_line_no_comment_for_empty}${ch_empty}"
          fi
          ((l_empty++))
        done
        last_line_no_comment_trimmed_empty="${last_line_no_comment_for_empty%"${last_line_no_comment_for_empty##*[![:space:]]}"}"
        
        if [[ "${last_line_no_comment_trimmed_empty}" =~ \\$ ]]; then
          # Backslash continuation - always include empty line
          :
        elif [[ "${last_line_no_comment_trimmed_empty}" =~ \|$ ]]; then
          # Pipe continuation - always include empty line
          :
        elif [[ $inside_quotes -eq 1 ]]; then
          # Inside unclosed quotes - include empty line as part of the quoted command
          :
        elif [[ $inside_block -eq 1 ]]; then
          # Inside incomplete block - include empty line as part of the block
          :
        else
          # Empty line and no backslash/pipe continuation and not in quotes and not in block - this separates commands
          # Test if command would be complete - if adding the empty line makes it complete, it's just a separator
          # Decrement indices since we already incremented them, and the main loop will skip the empty line
          ((ARRAY_INDEX--))
          ((LINE_NUMBER--))
          break
        fi
      fi
      
      # If next line starts with # (and isn't a control flag), include it if inside quotes, inside a block, or if command has backslash/pipe continuation
      # Otherwise, comments separate commands, so break
      if [[ "${next_line}" =~ ^[[:space:]]*# ]] && ! [[ "${next_line}" =~ ^#_ECHO ]]; then
        # Check the last non-empty line of the accumulated command for continuation markers
        # Need to check the actual last line, not just trimmed version, to handle inline comments
        last_line_of_command=$(echo "$command" | grep -v '^[[:space:]]*$' | tail -n 1)
        if [[ -z "$last_line_of_command" ]]; then
          # If all lines are empty, get the actual last line
          last_line_of_command=$(echo "$command" | tail -n 1)
        fi
        # Use helper function to strip inline comments from the last line
        last_line_no_comment=$(_strip_inline_comment_from_line "$last_line_of_command")
        last_line_no_comment_trimmed="${last_line_no_comment%"${last_line_no_comment##*[![:space:]]}"}"
        if [[ "${last_line_no_comment_trimmed}" =~ \\$ ]]; then
          # Backslash continuation - include comment in display but skip it in command execution
          # Add to display_command for display purposes
          display_command="${display_command}"$'\n'"${next_line}"
          # Skip adding to command - comments can't be part of executable syntax
          # Continue to next line without breaking
          comment_after_continuation=1
        elif [[ "${last_line_no_comment_trimmed}" =~ \|$ ]]; then
          # Pipe continuation - include comment in display but skip it in command execution
          # Add to display_command for display purposes
          display_command="${display_command}"$'\n'"${next_line}"
          # Skip adding to command - comments can't be part of executable syntax
          # Continue to next line without breaking (the continue at end of comment handling will skip normal processing)
          comment_after_continuation=1
        elif [[ $inside_quotes -eq 1 ]]; then
          # Inside unclosed quotes - include comment as part of the quoted command
          :
        elif [[ $inside_block -eq 1 ]]; then
          # Inside incomplete block - include comment as part of the block
          :
        else
          # Comment and no backslash/pipe continuation and not in quotes and not in block - this separates commands
          # Decrement indices since we already incremented them, and the main loop will skip the comment
          ((ARRAY_INDEX--))
          ((LINE_NUMBER--))
          break
        fi
      fi
      
      # If we handled a comment after pipe/backslash above, skip adding it to command and continue to next line
      if [[ "${comment_after_continuation:-0}" -eq 1 ]]; then
        comment_after_continuation=0
        # Continue loop to get next line (don't add comment to command)
        continue
      fi
      
      # Track original format for display (always preserve original format)
      display_command="${display_command}"$'\n'"${next_line}"
      
      # Combine lines - need to check last non-empty line without inline comments for continuation markers
      last_line_for_combine=$(echo "$command" | grep -v '^[[:space:]]*$' | tail -n 1)
      if [[ -z "$last_line_for_combine" ]]; then
        # If all lines are empty, get the actual last line
        last_line_for_combine=$(echo "$command" | tail -n 1)
      fi
      last_line_trimmed_for_combine="${last_line_for_combine%"${last_line_for_combine##*[![:space:]]}"}"
      # Use helper function to remove inline comments from the last line to check for pipe/backslash
      last_line_no_comment_for_combine=$(_strip_inline_comment_from_line "$last_line_trimmed_for_combine")
      last_line_no_comment_trimmed_combine="${last_line_no_comment_for_combine%"${last_line_no_comment_for_combine##*[![:space:]]}"}"
      
      if [[ "${last_line_no_comment_trimmed_combine}" =~ \\$ ]]; then
        # Backslash continuation - remove backslash and combine with space
        has_backslash_continuation=1  # Mark that we have backslash continuation
        # Remove backslash from the last line (need to strip inline comment first, then remove backslash)
        # Actually, we need to remove backslash from the original line, not the comment-stripped version
        # So we'll work with the original last line
        last_line_original=$(echo "$command" | tail -n 1)
        # Remove trailing backslash (might have whitespace after it)
        last_line_no_backslash="${last_line_original%\\}"
        last_line_no_backslash="${last_line_no_backslash%"${last_line_no_backslash##*[![:space:]]}"}"
        # Replace the last line in command
        # Use sed to remove last line instead of head -n -1 (more portable)
        command_without_last=$(echo "$command" | sed '$d' 2>/dev/null || echo "")
        if [[ -n "$command_without_last" ]]; then
          command="${command_without_last}"$'\n'"${last_line_no_backslash}"
        else
          command="${last_line_no_backslash}"
        fi
        command="${command} ${next_line}"
      elif [[ "${last_line_no_comment_trimmed_combine}" =~ \|$ ]]; then
        # Pipe continuation - keep pipe and combine with space (pipe stays, just add next line)
        has_pipe_continuation=1  # Mark that we have pipe continuation
        # Strip inline comment from the last non-empty line using helper function, then combine with next_line
        # Find the last non-empty line (the one with the pipe)
        last_non_empty_line=$(echo "$command" | grep -v '^[[:space:]]*$' | tail -n 1)
        if [[ -z "$last_non_empty_line" ]]; then
          # If all lines are empty, get the actual last line
          last_non_empty_line=$(echo "$command" | tail -n 1)
        fi
        last_line_stripped=$(_strip_inline_comment_from_line "$last_non_empty_line")
        # Remove trailing whitespace before combining (we'll add a space before next_line)
        last_line_stripped_trimmed="${last_line_stripped%"${last_line_stripped##*[![:space:]]}"}"
        # Replace the last non-empty line in command with the stripped version, then combine with next_line on the same line
        # Find the line number of the last non-empty line
        last_non_empty_line_num=$(echo "$command" | grep -n '.' | tail -n 1 | cut -d: -f1)
        if [[ -n "$last_non_empty_line_num" && $last_non_empty_line_num -gt 1 ]]; then
          # Get lines before the last non-empty line
          lines_before=$(echo "$command" | head -n $((last_non_empty_line_num - 1)) 2>/dev/null || echo "")
          # Rebuild command: lines before + (stripped last line + space + next_line combined on same line)
          command="${lines_before}"$'\n'"${last_line_stripped_trimmed} ${next_line}"
        else
          # First line or all empty - just combine directly
          command="${last_line_stripped_trimmed} ${next_line}"
        fi
      else
        # No backslash or pipe but command incomplete - combine with newline
        command="${command}"$'\n'"${next_line}"
      fi
      
      # Check if command is now complete after combining - if so, exit loop
      if is_command_complete "$command"; then
        break
      fi
    done
  fi
  # Handle control flags
  if [[ "${command}" == "#_ECHO_ON" ]]; then
    ECHO=on
    ((LINE_NUMBER++))
    ((ARRAY_INDEX++))
    continue
  elif [[ "${command}" == "#_ECHO_OFF" ]]; then
    ECHO=off
    ((LINE_NUMBER++))
    ((ARRAY_INDEX++))
    continue
  elif [[ -z "${command//[[:space:]]/}" ]] || [[ $first_line_number -lt $START_WITH_LINE_NUMBER ]]; then
    # Skip blank or whitespace-only lines — used for readability in commands file only.
    # Also skip lines before the specified start point.
    ((LINE_NUMBER++))
    ((ARRAY_INDEX++))
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
    ((ARRAY_INDEX++))
    continue
  fi

  # Strip inline comments from command before execution using helper function
  command_no_inline_comments=$(_strip_comments_from_command "$command")
  # Preserve original command for display (with comments), but use stripped version for execution
  command_for_display="${command}"
  command="${command_no_inline_comments}"
  
  # When ECHO_OFF is active, execute command immediately (non-interactively);
  # output still appears unless explicitly redirected by the command itself.
  if [[ $ECHO == "off" ]]; then
    printf "%b" "${RESET_FONT}"
    eval "${command}"
    # Skip adding these to command history — user never saw them interactively
    ((LINE_NUMBER++))
    ((ARRAY_INDEX++))
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
  # Use original format for backslash/pipe-continued commands, otherwise use processed command
  if [[ ($has_backslash_continuation -eq 1 || $has_pipe_continuation -eq 1) ]] && [[ -n "${display_command}" ]]; then
    printf "%s" "${display_command}" | pv -qL "${DEMO_DELAY}"
    # For editing, use the original format so user can edit the multi-line version
    command_for_edit="${display_command}"
  else
    # Use command_for_display if available (preserves comments), otherwise use command
    display_cmd="${command_for_display:-${command}}"
    printf "%s" "${display_cmd}" | pv -qL "${DEMO_DELAY}"
    command_for_edit="${display_cmd}"
  fi
  PROMPT_STR=""
  edited=$(get_user_input "${command_for_edit}")
  echo
  printf "%b" "${RESET_FONT}"
  # For execution, convert backslash/pipe-continued commands back to combined format if needed
  if [[ ($has_backslash_continuation -eq 1 || $has_pipe_continuation -eq 1) ]] && [[ -n "${display_command}" ]]; then
    # Convert edited multi-line back to executable format (replace \ followed by newline with space)
    # Process line by line: if line ends with \, combine with next line using space
    exec_command=""
    IFS=$'\n' read -d '' -r -a lines <<< "${edited}" || true
    i=0
    while [ $i -lt ${#lines[@]} ]; do
      line="${lines[$i]}"
      # Remove leading whitespace from continuation lines (they're indented for readability)
      if [ $i -gt 0 ]; then
        line="${line#"${line%%[![:space:]]*}"}"  # Remove leading whitespace
      fi
      trimmed="${line%"${line##*[![:space:]]}"}"  # Remove trailing whitespace
      if [[ "${trimmed}" =~ \\$ ]] && [ $((i+1)) -lt ${#lines[@]} ]; then
        # Line ends with backslash - combine with next line
        exec_command="${exec_command}${line%\\}"
        exec_command="${exec_command%"${exec_command##*[![:space:]]}"}"  # Remove trailing whitespace
        exec_command="${exec_command} "
        ((i++))
        # Get next line and remove its leading whitespace, then process it
        next_line="${lines[$i]}"
        next_line="${next_line#"${next_line%%[![:space:]]*}"}"  # Remove leading whitespace
        # Check if next line also ends with backslash - if so, process it in next iteration
        next_trimmed="${next_line%"${next_line##*[![:space:]]}"}"
        if [[ "${next_trimmed}" =~ \\$ ]] && [ $((i+1)) -lt ${#lines[@]} ]; then
          # Next line also ends with backslash - add it without the backslash and continue
          exec_command="${exec_command}${next_line%\\}"
          exec_command="${exec_command%"${exec_command##*[![:space:]]}"}"  # Remove trailing whitespace
          exec_command="${exec_command} "
        else
          # Next line doesn't end with backslash - add it as-is
          exec_command="${exec_command}${next_line}"
        fi
      elif [[ "${trimmed}" =~ \|$ ]] && [ $((i+1)) -lt ${#lines[@]} ]; then
        # Line ends with pipe - combine with next non-comment line (keep the pipe)
        exec_command="${exec_command}${line}"
        exec_command="${exec_command%"${exec_command##*[![:space:]]}"}"  # Remove trailing whitespace
        exec_command="${exec_command} "
        ((i++))
        # Skip comment lines and empty lines until we find the next command line
        while [ $i -lt ${#lines[@]} ]; do
          next_line="${lines[$i]}"
          next_line_trimmed="${next_line#"${next_line%%[![:space:]]*}"}"  # Remove leading whitespace
          next_trimmed="${next_line_trimmed%"${next_line_trimmed##*[![:space:]]}"}"  # Remove trailing whitespace
          # Skip comment-only lines and empty lines
          if [[ -z "$next_trimmed" ]] || [[ "$next_line" =~ ^[[:space:]]*# ]]; then
            ((i++))
            continue
          fi
          # Found a non-comment line - process it
          next_line="${next_line#"${next_line%%[![:space:]]*}"}"  # Remove leading whitespace
          # Check if next line also ends with pipe - if so, process it in next iteration
          next_trimmed="${next_line%"${next_line##*[![:space:]]}"}"
          if [[ "${next_trimmed}" =~ \|$ ]] && [ $((i+1)) -lt ${#lines[@]} ]; then
            # Next line also ends with pipe - add it and continue
            exec_command="${exec_command}${next_line}"
            exec_command="${exec_command%"${exec_command##*[![:space:]]}"}"  # Remove trailing whitespace
            exec_command="${exec_command} "
          else
            # Next line doesn't end with pipe - add it as-is
            exec_command="${exec_command}${next_line}"
          fi
          break
        done
      else
        exec_command="${exec_command}${line}"
        if [ $((i+1)) -lt ${#lines[@]} ]; then
          exec_command="${exec_command}"$'\n'
        fi
      fi
      ((i++))
    done
    # Strip inline comments from exec_command before execution using helper function
    exec_command_no_comments=$(_strip_comments_from_command "$exec_command")
    eval "${exec_command_no_comments}"
    # Store original multi-line format in history
    CMD_HISTORY+=("${edited}")
  else
    # Strip inline comments from edited command before execution using helper function
    edited_no_comments=$(_strip_comments_from_command "$edited")
    eval "${edited_no_comments}"
    # Store in history as-is (preserves multiline format)
    CMD_HISTORY+=("${edited}")
  fi
  ((LINE_NUMBER++))
  ((ARRAY_INDEX++))
done


