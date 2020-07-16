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

const addGridLines = (direction, center, [min, max], element, lineBase, onLine, nextLine) => {
    const offset = coordOffset(nextLine, lineBase);
    const angle = -Math.atan2(...coordOffset(lineBase, onLine));
    for (let i = min; i <= max; i++) {
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

const addDimensionTicks = (elements, baseLine, nextLine, offsetProperty, coordinateLabel, axisSize, container, getIntersect) => {
  const baseCoordinate = Math.floor(container.dataset[coordinateLabel]/1000.0);
  
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
         intersect -= tickSep, coordinate --) {
      addAxisTick(element, coordinate, offsetProperty, intersect);
      if (coordinate < minCoord) minCoord = coordinate;
    }
    for (let intersect = nextTickIntersect, coordinate = baseCoordinate + 1;
         0 <= intersect && intersect <= axisLength;
         intersect += tickSep, coordinate ++) {
      addAxisTick(element, coordinate, offsetProperty, intersect);
      if (coordinate > maxCoord) maxCoord = coordinate;
    }
  }
  return [minCoord, maxCoord];
};

const addAllTicks = () => {
  for (const container of document.querySelectorAll('.container')) {
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
      'top', 'northing', 'height', container,
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
      'left', 'easting', 'width', container,
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
        cornerRelPos('.bottom.left'),
        cornerRelPos('.top.left'),
        cornerRelPos('.bottom.right'),
      );
      
      addGridLines('northing',
        Math.floor(container.dataset.northing/1000.0),
        northingBounds,
        gridLinesContainer,
        cornerRelPos('.bottom.left'),
        cornerRelPos('.bottom.right'),
        cornerRelPos('.top.left'),
      );
    }
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

window.addEventListener("afterprint", () => {
  // document.body.classList.remove('printing');
  addAllTicks();
});
window.addEventListener("beforeprint", () => {
  // document.body.classList.add('printing');
  addAllTicks();
});
window.addEventListener("DOMContentLoaded", () => {
  addAllTicks();
});

const addMap = async (direction) => {
  const res = await fetch(`/?center=${direction}&partial`);
  const html = await res.text();
  document.body.insertAdjacentHTML('beforeend',html);
  addAllTicks();
};
