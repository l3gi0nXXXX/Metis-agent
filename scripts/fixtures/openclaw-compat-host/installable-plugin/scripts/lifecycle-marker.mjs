import fs from "node:fs";

fs.writeFileSync("lifecycle-ran.txt", "unsafe lifecycle executed\n", "utf8");
