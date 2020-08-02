// Allow bulk disabling of radio nodes
Object.defineProperty(RadioNodeList.prototype, 'disabled', {
  get() {
    return Array.prototype.every.call(this, (node) => node.disabled);
  },
  set(value) {
    Array.prototype.forEach.call(this, (node) => {
      node.disabled = value;
    });
  },
});

const sleep = (t = 0) => new Promise((resolve) => setTimeout(resolve, t));

const makeSingleSleeper = () => {
  let timeout = 0;
  return (t = 0) =>
    new Promise((resolve) => {
      clearTimeout(timeout);
      timeout = setTimeout(resolve, t);
    });
};

const lineExtension = (xy1, xy2, x) => {
  const [x1, y1] = xy1;
  const [x2, y2] = xy2;
  return ((y2 - y1) / (x2 - x1)) * (x - x1) + y1;
};

const proportion = (a, b, p) => a * (1 - p) + b * p;

const transpose = (m) => m[0].map((x, i) => m.map((x) => x[i]));

const coordOffset = (a, b, m = -1) =>
  transpose([a, b]).map(([a, b]) => a + m * b);

const makeGridLine = (direction, style) => {
  const line = document.createElement('div');
  line.classList.add('grid-line');
  line.classList.add(direction);
  Object.assign(line.style, style);
  return line;
};

const addGridLines = (
  direction,
  center,
  [min, max],
  element,
  skip,
  lineBase,
  onLine,
  nextLine
) => {
  const offset = coordOffset(nextLine, lineBase).map((a) => a / skip);
  const angle = -Math.atan2(...coordOffset(lineBase, onLine));
  for (let i = min; i <= max; i += skip) {
    const [left, top] = coordOffset(lineBase, offset, i - center).map(
      (d) => d * 100 + '%'
    );
    const transform = `rotate(${angle}rad)`;
    const line = makeGridLine(direction, { left, top, transform });
    line.dataset.i = i;
    element.appendChild(line);
  }
};

const mod = (x, n) => ((x % n) + n) % n;

const makeElement = (type, string = '', attrs = {}) => {
  const elem = document.createElement(type);
  if (string) elem.innerText = string;
  Object.assign(elem, attrs);
  return elem;
};

const makeLabel = (number, style) => {
  const label = document.createElement('div');
  label.classList.add('axis-label');
  Object.assign(label.style, style);
  const span = label.appendChild(
    makeElement('span', ('' + mod(number, 100)).padStart(2, '0'))
  );
  if (mod(number, 100) === 0) span.prepend(makeElement('sup', number / 100));
  return label;
};

const addAxisTick = (element, labelText, offsetProperty, offsetValue) => {
  element.appendChild(
    makeLabel(labelText, {
      [offsetProperty]: offsetValue + 'px',
    })
  );
};

const addDimensionTicks = (
  elements,
  baseLine,
  nextLine,
  offsetProperty,
  coordinateLabel,
  axisSize,
  page,
  skip,
  getIntersect
) => {
  const baseCoordinate =
    Math.floor(page.dataset[coordinateLabel] / 1000 / skip) * skip;

  let minCoord = baseCoordinate;
  let maxCoord = baseCoordinate;
  for (const element of elements) {
    element.innerHTML = '';
    const bounds = element.getBoundingClientRect();

    const baseTickIntersect = getIntersect(bounds, baseLine);
    const nextTickIntersect = getIntersect(bounds, nextLine);
    const axisLength = bounds[axisSize];
    const tickSep = nextTickIntersect - baseTickIntersect;

    if (tickSep == 0) {
      addAxisTick(element, baseCoordinate, offsetProperty, baseTickIntersect);
      continue;
    }

    for (
      let intersect = baseTickIntersect, coordinate = baseCoordinate;
      0 <= intersect && intersect <= axisLength;
      intersect -= tickSep, coordinate -= skip
    ) {
      addAxisTick(element, coordinate, offsetProperty, intersect);
      if (coordinate < minCoord) minCoord = coordinate;
    }
    for (
      let intersect = nextTickIntersect, coordinate = baseCoordinate + skip;
      0 <= intersect && intersect <= axisLength;
      intersect += tickSep, coordinate += skip
    ) {
      addAxisTick(element, coordinate, offsetProperty, intersect);
      if (coordinate > maxCoord) maxCoord = coordinate;
    }
  }
  return [minCoord, maxCoord];
};

const addAllTicks = () => {
  for (const page of document.querySelectorAll('.page')) {
    const skip = +page.dataset.skip;
    const cornerXY = (selector) => {
      const { x, y } = page
        .querySelector(`.center ${selector}`)
        .getBoundingClientRect();
      return [x, y];
    };
    const cornerRelPos = (selector) => {
      const { left, top } = page.querySelector(`.center ${selector}`).dataset;
      return [parseFloat(left), parseFloat(top)];
    };

    const northingBounds = addDimensionTicks(
      page.querySelectorAll('.border.horizontal'),
      [cornerXY('.bottom.left'), cornerXY('.bottom.right')],
      [cornerXY('.top.left'), cornerXY('.top.right')],
      'top',
      'northing',
      'height',
      page,
      skip,
      (bounds, [corner1, corner2]) =>
        lineExtension(corner1, corner2, (bounds.left + bounds.right) / 2) -
        bounds.y
    );

    const eastingBounds = addDimensionTicks(
      page.querySelectorAll('.border.vertical'),
      [cornerXY('.bottom.left'), cornerXY('.top.left')],
      [cornerXY('.bottom.right'), cornerXY('.top.right')],
      'left',
      'easting',
      'width',
      page,
      skip,
      (bounds, [corner1, corner2]) =>
        lineExtension(
          corner1.slice().reverse(),
          corner2.slice().reverse(),
          (bounds.top + bounds.bottom) / 2
        ) - bounds.x
    );

    const gridLinesElem = page.querySelector('.grid-lines');
    if (gridLinesElem) {
      gridLinesElem.innerHTML = '';
      addGridLines(
        'easting',
        Math.floor(page.dataset.easting / 1000.0),
        eastingBounds,
        gridLinesElem,
        skip,
        cornerRelPos('.bottom.left'),
        cornerRelPos('.top.left'),
        cornerRelPos('.bottom.right')
      );

      addGridLines(
        'northing',
        Math.floor(page.dataset.northing / 1000.0),
        northingBounds,
        gridLinesElem,
        skip,
        cornerRelPos('.bottom.left'),
        cornerRelPos('.bottom.right'),
        cornerRelPos('.top.left')
      );
    }
  }
};

const addDescendantEventListener = (parent, events, selector, handler) => {
  const wrappedHandler = (e) => {
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

window.addEventListener('DOMContentLoaded', () => {
  addAllTicks();

  const form = document.querySelector('form');
  addDescendantEventListener(form, 'click input', 'label > input', function (
    e
  ) {
    const hiddenSibling = (radio) =>
      radio.parentElement.querySelector('input[type="hidden"]');
    const inputSibling = (radio) =>
      radio.parentElement.querySelector(
        'input:not([type="radio"]):not([type="hidden"])'
      );
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

  const onRangeChange = (slider) => {
    const value = Math.pow(2, slider.value);
    form.elements.scale.value = value;
    form.querySelector('#scale-reading').innerText = Math.max(value, 1);
    form.querySelector('#scale-reading-reciprocal').innerText = Math.max(
      1 / value,
      1
    );
  };

  const selectedElement = (select) => select.options[select.selectedIndex];

  addDescendantEventListener(
    form,
    'dblclick',
    '.zoom-control > span',
    function () {
      const zoomField = form.elements.zoom;
      const slider = form.querySelector('.scale-control input[type="range"]');
      const scale = selectedElement(form.elements.style).dataset.scale || 0;
      zoomField.value = +slider.value + 12 + +scale;
      // TODO: round to nearest
    }
  );

  addDescendantEventListener(form, 'change', '.zoom-dropdown', function () {
    const zoomField = form.elements.zoom;
    const zoomDropdown = this;
    zoomField.value = this.value;
  });

  addDescendantEventListener(
    form,
    'dblclick',
    '.scale-control > span',
    function (e) {
      const zoom = +form.elements.zoom.value;
      const slider = form.querySelector('.scale-control input[type="range"]');
      const scale = selectedElement(form.elements.style).dataset.scale || 0;
      slider.value = zoom - 12 - +scale;
      onRangeChange(slider);
    }
  );

  addDescendantEventListener(
    form,
    'input',
    '.range input[type="range"]',
    function (e) {
      onRangeChange(this);
    }
  );

  addDescendantEventListener(form, 'change', '[name="style"]', function (e) {
    const option = this.selectedOptions[0];
    const zooms = option ? JSON.parse(option.dataset.zooms) : [];
    const zoomField = form.querySelector('.zoom-control');
    const zoomDropdown = form.querySelector('.zoom-dropdown');
    const input = zoomField.querySelector('input');
    const choiceOfZoom = zooms.length > 1;
    const zoomIncrements = new Set(
      (function* (array) {
        for (let i = 0; i < array.length - 1; i++)
          yield array[i + 1] - array[i];
      })(zooms)
    );
    zoomField.classList.toggle('invisible', !choiceOfZoom);
    input.disabled = !choiceOfZoom;
    input.min = Math.min(...zooms);
    input.max = Math.max(...zooms);
    if (+input.value < +input.min) input.value = input.min;
    else if (+input.value > +input.max) input.value = input.max;
    if (zoomIncrements.size <= 1) {
      input.step = zoomIncrements.values().next().value;
      input.classList.remove('hidden');
      zoomDropdown.classList.add('hidden');
    } else {
      input.classList.add('hidden');
      zoomDropdown.classList.remove('hidden');
      zoomDropdown.innerText = '';
      for (const zoom of zooms) {
        zoomDropdown.appendChild(
          makeElement('option', zoom, {
            value: zoom,
            selected: input.value == zoom,
          })
        );
      }
    }
  });

  form.addEventListener('submit', (e) => {
    const formMap = new URLSearchParams();
    for (const element of form.elements) {
      if (element.name && element.value && !element.disabled)
        formMap.set(element.name, element.value);
    }
    e.preventDefault();
    const url = form.action + '?' + formMap;
    // TODO: history API and AJAX
    location.href = url;
  });

  addDescendantEventListener(document.body, 'click', '.minimap td', function (
    e
  ) {
    const target = this.dataset.center;
    document.querySelector(`.page[data-center="${target}"]`).scrollIntoView();
    console.log(target);
  });
});

const addMap = async (direction) => {
  const res = await fetch(`/?center=${direction}&partial`);
  const html = await res.text();
  document.body.insertAdjacentHTML('beforeend', html);
  addAllTicks();
};
