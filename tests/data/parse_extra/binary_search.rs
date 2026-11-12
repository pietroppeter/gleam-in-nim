use std::cmp::Ordering;
fn main(){
  // deterministic LCG
  let mut x: u64 = 12345;
  let mut next = || { x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407); (x >> 33) as u32 };
  for _ in 0..2000 {
    let n = (next() % 12) as usize;
    let mut v: Vec<(u32,u32)> = vec![]; let mut pos = 0;
    for _ in 0..n { let s = pos + next()%5; let e = s + next()%6; v.push((s,e)); pos = e + next()%4; }
    let start = next()%40; let end = start + next()%30;
    let r = v.binary_search_by(|c| if c.1 < start {Ordering::Less} else if c.0 > end {Ordering::Greater} else {Ordering::Equal});
    let spans: Vec<String> = v.iter().map(|c| format!("{}-{}", c.0, c.1)).collect();
    println!("{} {} {} {}", spans.join(","), start, end, match r { Ok(i)=>i as i64, Err(_)=>-1 });
  }
}
