import test from "node:test";
import assert from "node:assert/strict";
import { decodeBase32, parseImport, totp, remaining, formatCode, toURI, editAccount } from "../src/totp.ts";

function base32(bytes: Buffer): string {
  let accumulator = 0, bits = 0, output = "";
  for (const byte of bytes) {
    accumulator = (accumulator << 8) | byte;
    bits += 8;
    while (bits >= 5) { bits -= 5; output += "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"[(accumulator >>> bits) & 31]; }
  }
  if (bits) output += "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"[(accumulator << (5 - bits)) & 31];
  return output;
}
// RFC 6238 Appendix B, SHA1/SHA256/SHA512 at all six published timestamps.
const vectors = [
  [59,"94287082","46119246","90693936"],
  [1111111109,"07081804","68084774","25091201"],
  [1111111111,"14050471","67062674","99943326"],
  [1234567890,"89005924","91819424","93441116"],
  [2000000000,"69279037","90698825","38618901"],
  [20000000000,"65353130","77737706","47863826"],
] as const;
for (const [index, algorithm, length] of [[1,"SHA1",20],[2,"SHA256",32],[3,"SHA512",64]] as const) {
  test(`${algorithm} matches RFC 6238`, () => {
    const secret = base32(Buffer.from("1234567890".repeat(7).slice(0,length)));
    const [account] = parseImport(`otpauth://totp/Test:user?secret=${secret}&algorithm=${algorithm}&digits=8`);
    for (const row of vectors) assert.equal(totp(account,row[0]*1000),row[index]);
  });
}
test("imports encoded labels, eight digits, SHA256 and custom periods", () => {
  const [account] = parseImport("otpauth://totp/Microsoft%3Auser%40example.test?secret=GEZDGNBVGY3TQOJQ&issuer=Microsoft&digits=8&algorithm=SHA256&period=60");
  assert.equal(account.name,"user@example.test");
  assert.equal(account.digits,8);
  assert.equal(remaining(account,59000),1);
  assert.equal(remaining(account,60000),60);
  assert.notEqual(totp(account,59999),totp(account,60000));
});
test("import is atomic and never echoes secret input in errors", () => {
  for (const query of ["secret=SECRET!", "secret=MY&digits=3", "secret=MY&period=0", "secret=MY&algorithm=MD5"]) {
    assert.throws(() => parseImport("otpauth://totp/Test?"+query), {message:"The import contains an invalid or unsupported TOTP entry"});
  }
  assert.throws(() => parseImport("otpauth://hotp/Test?secret=MY"));
  assert.throws(() => decodeBase32("MZ"));
  assert.equal(decodeBase32("MY======").toString(),"f");
});
test("deduplicates exact entries and retains distinct accounts", () => {
  const line="otpauth://totp/Test:one?secret=MY";
  assert.equal(parseImport(line+"\n"+line+"\notpauth://totp/Test:two?secret=MY").length,2);
  assert.equal(formatCode("12345678"),"1234 5678");
  assert.equal(formatCode("001234"),"001 234");
});
test("export round trips labels, keys and all TOTP settings", () => {
  const [original] = parseImport("otpauth://totp/Test%3Auser?secret=GEZDGNBVGY3TQOJQ&algorithm=SHA512&digits=8&period=60");
  const changed = editAccount(original, { issuer: "A & B, / 中文", name: "user+test@example.test", secret: "gezd gnbv gy3t qojq", algorithm: "SHA256", digits: "8", period: "45" });
  const [restored] = parseImport(toURI(changed));
  assert.equal(changed.id, original.id);
  for (const field of ["issuer", "name", "secret", "algorithm", "digits", "period"] as const) assert.equal(restored[field], changed[field]);
  assert.equal(totp(changed, 1234567890000), totp(restored, 1234567890000));
  assert.throws(() => editAccount(original, { issuer: "Test", name: "user", secret: "bad!", algorithm: "SHA1", digits: "6", period: "30" }));
});
