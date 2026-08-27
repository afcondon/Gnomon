// Launcher for the compiled backend. A real file rather than `node -e`,
// because Main reads `Array.drop 2 Process.argv` — the ordinary shape when
// argv[1] is a script path, and wrong by one when `-e` leaves it absent.
import { main } from "../output/Main/index.js";
main();
