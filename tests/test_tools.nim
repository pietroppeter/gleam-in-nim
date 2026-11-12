## The tools of the port test themselves: the snapshot reader and the harvester of Rust test
## macros, on small inputs written here (no reference checkout needed).
import ../tools/[snapshots, harvest]

snapshots.selfTest()
harvest.selfTest()
