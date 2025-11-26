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
  echo "  - For ad-hoc commands, escape sequences and control characters other than arrow keys, Backspace, and Return are currently ignored (e.g., Tab, Ctrl+L)."
  echo "  - Tab autocompletion is currently not supported."
  echo "  - Ad-hoc multi-line commands are not supported (only scripted multi-line commands)."
  echo "  - For scripted multi-line commands, editing is not supported (left arrow and Backspace are disabled)."
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
  # Clear current line first
  printf "\r\033[K" >>/dev/tty
  # Display the multiline command with prompt on first line only
  printf "%b" "$prompt" >>/dev/tty
  # Split by newlines and display each line
  IFS=$'\n' read -d '' -r -a lines <<< "$buf" || true
  local i=0
  for line in "${lines[@]}"; do
    if [ $i -eq 0 ]; then
      # First line: already have prompt, just print the line
      printf "%s" "$line" >>/dev/tty
    else
      # Subsequent lines: newline, then the line (no prompt)
      printf "\n%s" "$line" >>/dev/tty
    fi
    ((i++))
  done
  # Cursor is already at the end of the last line after printing
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
      # Disable backspace for multiline commands (too complex to handle properly)
      if [[ "$temp_command" =~ $'\n' ]]; then
        continue
      fi
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
                  # Clear current command display
                  if [[ "$temp_command" =~ $'\n' ]]; then
                    # Count newlines to determine how many display lines we have
                    local newline_count=$(echo -n "$temp_command" | tr -cd '\n' | wc -c | tr -d ' ')
                    local total_display_lines=$((newline_count + 1))  # +1 for prompt line
                    # Clear all lines: start with current line, then move up and clear each line
                    local i=0
                    while [ $i -lt $total_display_lines ]; do
                      if [ $i -eq 0 ]; then
                        # Clear current line
                        printf "\r\033[K" >>/dev/tty
                      else
                        # Move up and clear
                        printf "\033[1A\033[K" >>/dev/tty
                      fi
                      ((i++))
                    done
                  else
                    printf "\r\033[K" >>/dev/tty
                  fi
                  ((history_index--))
                  temp_command="${CMD_HISTORY[$history_index]}"
                  cursor=${#temp_command}
                  # Display the new command
                  if [[ "$temp_command" =~ $'\n' ]]; then
                    _redraw_multiline "$prompt" "$temp_command" "$cursor"
                  else
                    _redraw_line "$prompt" "$temp_command" "$cursor"
                  fi
                fi
              fi ;;
          B)  # Down (move forward in history)
              if (( ${#CMD_HISTORY[@]} > 0 )); then
                if (( history_index < ${#CMD_HISTORY[@]} )); then
                  # Clear current command display
                  if [[ "$temp_command" =~ $'\n' ]]; then
                    # Count newlines to determine how many display lines we have
                    local newline_count=$(echo -n "$temp_command" | tr -cd '\n' | wc -c | tr -d ' ')
                    local total_display_lines=$((newline_count + 1))  # +1 for prompt line
                    # Clear all lines: start with current line, then move up and clear each line
                    local i=0
                    while [ $i -lt $total_display_lines ]; do
                      if [ $i -eq 0 ]; then
                        # Clear current line
                        printf "\r\033[K" >>/dev/tty
                      else
                        # Move up and clear
                        printf "\033[1A\033[K" >>/dev/tty
                      fi
                      ((i++))
                    done
                  else
                    printf "\r\033[K" >>/dev/tty
                  fi
                  ((history_index++))
                  if (( history_index == ${#CMD_HISTORY[@]} )); then
                    temp_command="$history_in_progress"
                  else
                    temp_command="${CMD_HISTORY[$history_index]}"
                  fi
                  cursor=${#temp_command}
                  # Display the new command
                  if [[ "$temp_command" =~ $'\n' ]]; then
                    _redraw_multiline "$prompt" "$temp_command" "$cursor"
                  else
                    _redraw_line "$prompt" "$temp_command" "$cursor"
                  fi
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

# Function to check if a command line is complete (not continued on next line)
# Returns 0 if complete, 1 if incomplete
is_command_complete() {
  local cmd="$1"
  local trimmed="${cmd%"${cmd##*[![:space:]]}"}"  # Remove trailing whitespace
  
  # Check for backslash continuation (most common case)
  if [[ "${trimmed}" =~ \\$ ]]; then
    return 1  # Incomplete - has backslash continuation
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
  display_command=""  # For backslash-continued commands, preserve original format
  has_backslash_continuation=0
  
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
    # Check if first line has backslash continuation
    first_trimmed="${command%"${command##*[![:space:]]}"}"
    if [[ "${first_trimmed}" =~ \\$ ]]; then
      has_backslash_continuation=1
      display_command="${command}"
    else
      # Initialize display_command even if first line doesn't have backslash
      # (backslashes might appear later in the block)
      display_command="${command}"
    fi
    
    # For regular commands, check if they're complete or need continuation
    while ! is_command_complete "$command"; do
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
      
      # If we hit an empty line, include it if inside a block or if command has backslash continuation
      # Otherwise, empty lines separate commands, so break to let is_command_complete check handle it
      if [[ -z "${next_line//[[:space:]]/}" ]]; then
        trimmed="${command%"${command##*[![:space:]]}"}"
        if [[ "${trimmed}" =~ \\$ ]]; then
          # Backslash continuation - always include empty line
          :
        elif [[ $inside_block -eq 1 ]]; then
          # Inside incomplete block - include empty line as part of the block
          :
        else
          # Empty line and no backslash continuation and not in block - this separates commands
          # Test if command would be complete - if adding the empty line makes it complete, it's just a separator
          # Decrement indices since we already incremented them, and the main loop will skip the empty line
          ((ARRAY_INDEX--))
          ((LINE_NUMBER--))
          break
        fi
      fi
      
      # If next line starts with # (and isn't a control flag), include it if inside a block or if command has backslash continuation
      # Otherwise, comments separate commands, so break
      if [[ "${next_line}" =~ ^[[:space:]]*# ]] && ! [[ "${next_line}" =~ ^#_ECHO ]]; then
        prev_trimmed="${command%"${command##*[![:space:]]}"}"
        if [[ "${prev_trimmed}" =~ \\$ ]]; then
          # Backslash continuation - always include comment
          :
        elif [[ $inside_block -eq 1 ]]; then
          # Inside incomplete block - include comment as part of the block
          :
        else
          # Comment and no backslash continuation and not in block - this separates commands
          # Decrement indices since we already incremented them, and the main loop will skip the comment
          ((ARRAY_INDEX--))
          ((LINE_NUMBER--))
          break
        fi
      fi
      
      # Track original format for display (always preserve original format)
      display_command="${display_command}"$'\n'"${next_line}"
      
      # Combine lines
      trimmed="${command%"${command##*[![:space:]]}"}"
      if [[ "${trimmed}" =~ \\$ ]]; then
        # Backslash continuation - remove backslash and combine with space
        has_backslash_continuation=1  # Mark that we have backslash continuation
        command="${command%\\}"
        command="${command%"${command##*[![:space:]]}"}"
        command="${command} ${next_line}"
      else
        # No backslash but command incomplete - combine with newline
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
  # Use original format for backslash-continued commands, otherwise use processed command
  if [[ $has_backslash_continuation -eq 1 ]] && [[ -n "${display_command}" ]]; then
    printf "%s" "${display_command}" | pv -qL "${DEMO_DELAY}"
    # For editing, use the original format so user can edit the multi-line version
    command_for_edit="${display_command}"
  else
    printf "%s" "${command}" | pv -qL "${DEMO_DELAY}"
    command_for_edit="${command}"
  fi
  PROMPT_STR=""
  edited=$(get_user_input "${command_for_edit}")
  echo
  printf "%b" "${RESET_FONT}"
  # For execution, convert backslash-continued commands back to combined format if needed
  if [[ $has_backslash_continuation -eq 1 ]] && [[ -n "${display_command}" ]]; then
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
      else
        exec_command="${exec_command}${line}"
        if [ $((i+1)) -lt ${#lines[@]} ]; then
          exec_command="${exec_command}"$'\n'
        fi
      fi
      ((i++))
    done
    eval "${exec_command}"
    # Store original multi-line format in history
    CMD_HISTORY+=("${edited}")
  else
    eval "${edited}"
    # Store in history as-is (preserves multiline format)
    CMD_HISTORY+=("${edited}")
  fi
  ((LINE_NUMBER++))
  ((ARRAY_INDEX++))
done

