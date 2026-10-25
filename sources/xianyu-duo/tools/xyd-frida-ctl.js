import ObjC from 'frida-objc-bridge';

function log(m) { send({ m: m }); }

setTimeout(function () {
  try {
    var host = ObjC.classes.XYDBallHost.shared();
    log('host=' + host);
    host.onTap();
    log('tapped');
  } catch (e) { log('tap err ' + e); }
}, 300);

setTimeout(function () {
  try {
    var panels = ObjC.chooseSync(ObjC.classes.XYDPanelVC);
    log('panels=' + panels.length);
    if (!panels.length) return;
    var p = panels[0];
    log('itemId=' + p.itemId());
    p.reloadMedia();
    setTimeout(function () {
      try {
        var items = p.items();
        log('items=' + items.count());
        var sel = p.selected();
        for (var i = 0; i < items.count(); i++) {
          var it = items.objectAtIndex_(i);
          var kind = it.kind();
          var key = it.key().toString();
          log('item' + i + ' kind=' + kind + ' key=' + key);
          if (kind == 1) sel.addObject_(it.key());
        }
        log('selected=' + sel.count());
        p.saveSelected();
        log('save called');
      } catch (e) { log('save err ' + e); }
    }, 3000);
  } catch (e) { log('panel err ' + e); }
}, 2000);

log('ctl ready');
