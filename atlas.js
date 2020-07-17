// Allow bulk disabling of radio nodes
Object.defineProperty(RadioNodeList.prototype, 'disabled', {
    get() {
      return Array.prototype.every.call(this, node => node.disabled);
    },
    set(value) {
      Array.prototype.forEach.call(this, node => { node.disabled = value; });
    },
});

const sleep = (t = 0) => new Promise(resolve => setTimeout(resolve, t));

const makeSingleSleeper = () => {
  let timeout = 0;
  return (t = 0) => new Promise(resolve => {
    clearTimeout(timeout);
    timeout = setTimeout(resolve, t);
  });
}

const lineExtension = (xy1, xy2, x) => {
  const [x1, y1] = xy1;
  const [x2, y2] = xy2;
  return (y2-y1)/(x2-x1) * (x - x1) + y1;
}

const proportion = (a, b, p) => a * (1-p) + b * p;

const transpose = m => m[0].map((x,i) => m.map(x => x[i]));

const coordOffset = (a, b, m = -1) => transpose([a,b]).map(([a, b]) => a + m * b);

const makeGridLine = (direction, style) => {
  const line = document.createElement('div');
  line.classList.add('grid-line');
  line.classList.add(direction);
  Object.assign(line.style, style);
  return line;
};

const addGridLines = (direction, center, [min, max], element, skip, lineBase, onLine, nextLine) => {
  const offset = coordOffset(nextLine, lineBase).map(a => a / skip);
  const angle = -Math.atan2(...coordOffset(lineBase, onLine));
  for (let i = min; i <= max; i += skip) {
    const [left, top] = coordOffset(lineBase, offset, i - center).map(d => d*100+'%');
    const transform = `rotate(${angle}rad)`;
    const line = makeGridLine(direction, { left, top, transform });
    line.dataset.i=i;
    element.appendChild(line);
  }
};

const makeLabel = (number, style) => {
  const label = document.createElement('div');
  label.classList.add('axis-label');
  label.innerText = (""+number).slice(-2);
  Object.assign(label.style, style);
  return label;
};

const addAxisTick = (element, labelText, offsetProperty, offsetValue) => {
  element.appendChild(
    makeLabel(labelText, {
      [offsetProperty]: offsetValue + 'px',
    }),
  );
};

const addDimensionTicks = (elements, baseLine, nextLine, offsetProperty, coordinateLabel, axisSize, container, skip, getIntersect) => {
  const baseCoordinate = Math.floor(container.dataset[coordinateLabel] / 1000 / skip) * skip;

  let minCoord = baseCoordinate;
  let maxCoord = baseCoordinate;
  for (const element of elements) {
    element.innerHTML = '';
    const bounds = element.getBoundingClientRect();

    const baseTickIntersect = getIntersect(bounds, baseLine);
    const nextTickIntersect = getIntersect(bounds, nextLine);
    const axisLength = bounds[axisSize];
    const tickSep = nextTickIntersect - baseTickIntersect;

    for (let intersect = baseTickIntersect, coordinate = baseCoordinate;
      0 <= intersect && intersect <= axisLength;
      intersect -= tickSep, coordinate -= skip) {
      addAxisTick(element, coordinate, offsetProperty, intersect);
      if (coordinate < minCoord) minCoord = coordinate;
    }
    for (let intersect = nextTickIntersect, coordinate = baseCoordinate + skip;
      0 <= intersect && intersect <= axisLength;
      intersect += tickSep, coordinate += skip) {
      addAxisTick(element, coordinate, offsetProperty, intersect);
      if (coordinate > maxCoord) maxCoord = coordinate;
    }
  }
  return [minCoord, maxCoord];
};

const addAllTicks = () => {
  for (const container of document.querySelectorAll('.container')) {
    const skip = +container.dataset.skip;
    const cornerXY = selector => {
      const { x, y } = container.querySelector(`.center ${selector}`).getBoundingClientRect();
      return [x, y];
    };
    const cornerRelPos = selector => {
      const { left, top } = container.querySelector(`.center ${selector}`).dataset;
      return [parseFloat(left), parseFloat(top)];
    };

    const northingBounds = addDimensionTicks(
      container.querySelectorAll('.border.horizontal'),
      [cornerXY('.bottom.left'), cornerXY('.bottom.right')],
      [cornerXY('.top.left'), cornerXY('.top.right')],
      'top', 'northing', 'height', container, skip,
      (bounds, [corner1, corner2]) => lineExtension(
        corner1,
        corner2,
        (bounds.left + bounds.right) / 2,
      ) - bounds.y,
    );

    const eastingBounds = addDimensionTicks(
      container.querySelectorAll('.border.vertical'),
      [cornerXY('.bottom.left'), cornerXY('.top.left')],
      [cornerXY('.bottom.right'), cornerXY('.top.right')],
      'left', 'easting', 'width', container, skip,
      (bounds, [corner1, corner2]) => lineExtension(
        corner1.slice().reverse(),
        corner2.slice().reverse(),
        (bounds.top + bounds.bottom) / 2,
      ) - bounds.x,
    );

    const gridLinesContainer = container.querySelector('.grid-lines');
    if (gridLinesContainer) {
      gridLinesContainer.innerHTML = '';
      addGridLines('easting',
        Math.floor(container.dataset.easting/1000.0),
        eastingBounds,
        gridLinesContainer,
        skip,
        cornerRelPos('.bottom.left'),
        cornerRelPos('.top.left'),
        cornerRelPos('.bottom.right'),
      );

      addGridLines('northing',
        Math.floor(container.dataset.northing/1000.0),
        northingBounds,
        gridLinesContainer,
        skip,
        cornerRelPos('.bottom.left'),
        cornerRelPos('.bottom.right'),
        cornerRelPos('.top.left'),
      );
    }
  }
};

const addDescendantEventListener = (parent, events, selector, handler) => {
  const wrappedHandler = e => {
    const target = e.target.closest(selector);
    if (target && parent.contains(target)) return handler.call(target, e);
  };
  for (const event of events.split(' ')) {
    parent.addEventListener(event, wrappedHandler);
  }
};

// Only when dynamically sized
/*
const resizeSleep = makeSingleSleeper();
window.addEventListener("resize", async () => {
  await resizeSleep(10);
  addAllTicks();
});
*/

window.addEventListener("load", () => {
  addAllTicks();

  const form = document.querySelector('form');
  addDescendantEventListener(form, 'click input', 'label > input', function(e) {
    const hiddenSibling = radio => radio.parentElement.querySelector('input[type="hidden"]');
    const inputSibling = radio => radio.parentElement.querySelector('input:not([type="radio"]):not([type="hidden"])');
    const thisRadio = this.parentElement.querySelector('input[type="radio"]');
    if (!thisRadio) return;
    const thisInput = inputSibling(this);
    thisRadio.checked = true;
    const allRadios = form.elements[thisRadio.name];
    for (const radio of allRadios) {
      hiddenSibling(radio).disabled = radio != thisRadio;
      inputSibling(radio).required = radio == thisRadio;
      inputSibling(radio).tabIndex = radio == thisRadio ? 0 : -1;
    }
    hiddenSibling(thisRadio).value = thisInput.value;
    this.required = true;
  });

  const onRangeChange = slider => {
    const value = Math.pow(2, slider.value);
    form.elements.scale.value = value;
    form.querySelector('#scale-reading').innerText = Math.max(value,1);
    form.querySelector('#scale-reading-reciprocal').innerText = Math.max(1/value,1);
  };

  addDescendantEventListener(form, 'dblclick', '.zoom-control > span', function(e) {
    const zoomField = form.elements.zoom;
    const slider = form.querySelector('.scale-control input[type="range"]');
    zoomField.value = +slider.value + 12;
  });

  addDescendantEventListener(form, 'dblclick', '.scale-control > span', function(e) {
    const zoom = +form.elements.zoom.value;
    const slider = form.querySelector('.scale-control input[type="range"]');
    slider.value = zoom - 12;
    onRangeChange(slider);
  });

  addDescendantEventListener(form, 'input', '.range input[type="range"]', function(e) {
    onRangeChange(this);
  });

  addDescendantEventListener(form, 'change', '[name="style"]', function(e) {
    const option = this.selectedOptions[0];
    const zooms = option ? JSON.parse(option.dataset.zooms) : [];
    const zoomField = form.querySelector('.zoom-control');
    const input = zoomField.querySelector('input');
    const choiceOfZoom = zooms.length > 1;
    zoomField.classList.toggle('hidden', !choiceOfZoom);
    input.disabled = !choiceOfZoom;
    input.min = Math.min(...zooms);
    input.max = Math.max(...zooms);
    if (+input.value < +input.min) input.value = input.min;
    else if (+input.value > +input.max) input.value = input.max;
  });

  form.addEventListener('submit', (e) => {
    const formMap = new URLSearchParams();
    for (const element of form.elements) {
      if (element.name && element.value && !element.disabled) formMap.set(element.name, element.value);
    }
    e.preventDefault();
    const url = form.action + '?' + formMap;
    // TODO: history API and AJAX
    location.href = url;
  });
});

const addMap = async (direction) => {
  const res = await fetch(`/?center=${direction}&partial`);
  const html = await res.text();
  document.body.insertAdjacentHTML('beforeend',html);
  addAllTicks();
};
