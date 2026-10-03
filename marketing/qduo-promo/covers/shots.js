/* Real QDuo recordings, cut for the covers: [take, frame number, x, y, w, h] in
 * take pixels (2 per screen point). Frame N is take time (N-1)/60; see film.js. */
window.SHOTS = {
  liquidSub:    ['liquid', 295, 508, 468, 660, 680],   // Liquid Glass ring, 更多 open
  donutSub:     ['donut', 265, 274, 468, 660, 680],    // 3D Glass ring, 更多 open
  donutRing:    ['donut', 211, 334, 458, 540, 560],    // 3D Glass ring, tilted toward the pointer
  capsuleDrop:  ['polish', 295, 282, 596, 880, 400],   // Capsule, 更多 dropdown open
  translate:    ['liquid', 559, 368, 328, 938, 156],   // translation result panel
  write:        ['donut', 637, 128, 316, 956, 230],    // writing result panel
  compare:      ['polish', 577, 254, 621, 940, 289],   // polish compare view
  read:         ['read', 481, 150, 600, 972, 170],     // read-aloud panel, word highlighted
  docHero:      ['donut', 265, 120, 120, 1560, 1080]   // the whole document window, 3D ring with 更多 open
};
/** Fill every [data-shot] element with its cut; the element's width sets the scale. */
window.placeShots = function () {
  const jobs = [];
  document.querySelectorAll('[data-shot]').forEach(el => {
    const [take, n, x, y, w, h] = SHOTS[el.dataset.shot];
    el.style.aspectRatio = `${w} / ${h}`;
    el.style.overflow = 'hidden';
    if (getComputedStyle(el).position === 'static') el.style.position = 'relative';
    let img = el.querySelector('img');
    if (!img) { img = document.createElement('img'); el.appendChild(img); }
    img.src = `../frames/${take}/${String(n).padStart(4, '0')}.jpg`;
    const s = el.clientWidth / w;
    Object.assign(img.style, { position: 'absolute', left: -x * s + 'px', top: -y * s + 'px', width: 1800 * s + 'px', maxWidth: 'none' });
    jobs.push(img.decode());
  });
  return Promise.all(jobs);
};
