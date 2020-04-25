lines=( )
while IFS= read -r line; do
  lines+=( "$line" )
done < "${1}"

#[[ -n $line ]] && lines+=( "$line" )

((LINE_NUMBER=0))
for l in "${lines[@]}"
do
	((LINE_NUMBER=LINE_NUMBER+1))
done

echo "$LINE_NUMBER lines"
