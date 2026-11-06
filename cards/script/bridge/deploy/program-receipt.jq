# CardFactory's ProgramDeployed event indexes all three arguments and has no data payload.
def address_topic: "0x000000000000000000000000" + ltrimstr("0x");

if .status != "0x1" or (.logs | type) != "array" then
  error("expected a successful receipt with logs")
else
  .
end |
(.transactionHash | ascii_downcase) as $hash |
[
  .logs[] |
  select(
    ((.address // "" | ascii_downcase) == $factory) and
    ((.topics // [] | map(ascii_downcase)) == [
      $topic, ($program | address_topic), $programId, ($provider | address_topic)
    ]) and
    (.data == "0x") and
    (.removed != true) and
    ((.transactionHash // $hash | ascii_downcase) == $hash)
  )
] | if length > 1 then error("duplicate ProgramDeployed evidence") else length == 1 end
