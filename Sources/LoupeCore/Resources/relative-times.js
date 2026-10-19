// The words for each <time datetime> in the conversation page, kept current where the page is.
// They're worked out as Swift's Date.RelativeFormatStyle(presentation: .named) in en_US words
// them when the page is written, so a time reads the same before and after an update: seconds
// rounded first, then the largest unit apart, an hour, minute or second rounded on the next
// unit down, a larger one counted from the edge of the day, week, month or year it's seen from.
// The app defines `firstWeekday` (1 for Sunday, as Calendar's) before this.

const relativeUnits = ['year', 'month', 'week', 'day', 'hour', 'minute', 'second'];
const relativeWords = new Intl.RelativeTimeFormat('en-US', { numeric: 'auto', style: 'long' });
// How far the page's clock is moved on from the real one, for a snapshot run to show times update.
let clockOffset = 0;

// Rewords every time in the page whose words have moved on; returns how many did.
function updateTimes() {
  const now = new Date(Date.now() + clockOffset);
  const words = new Map();
  let changed = 0;
  for (const time of document.querySelectorAll('time[datetime]')) {
    const datetime = time.getAttribute('datetime');
    if (!words.has(datetime)) {
      const date = new Date(datetime);
      words.set(datetime, isNaN(date) ? null : relativeTime(date, now));
    }
    const text = words.get(datetime);
    if (text === null || time.textContent === text) continue;
    time.textContent = text;
    changed += 1;
  }
  return changed;
}

// Moves the page's clock on by `milliseconds` from the real one and rewords the times.
function moveClock(milliseconds) {
  clockOffset = milliseconds;
  return updateTimes();
}

// The words for `date` seen at `now`, e.g. "3 minutes ago" or "yesterday".
function relativeTime(date, now) {
  if (date > now) return 'just now';
  const reference = new Date(date.getTime() + Math.round((now - date) / 1000) * 1000);
  const largest = nonZeroParts(reference, date, relativeUnits)[0] ?? { unit: 'second', value: 0 };
  const shown = ['hour', 'minute', 'second'].includes(largest.unit)
    ? rounded(reference, date, largest)
    : aligned(reference, date, largest.unit) ?? largest;
  return relativeWords.format(shown.value, shown.unit);
}

// The largest unit's count, rounded up where the next unit down is at least half of it, then
// put in a larger unit where that makes a whole one, as 60 minutes is an hour.
function rounded(reference, date, largest) {
  const index = relativeUnits.indexOf(largest.unit);
  const parts = Object.fromEntries(partsBetween(reference, date, relativeUnits.slice(index)).map(part => [part.unit, part.value]));
  let value = parts[largest.unit];
  const next = relativeUnits[index + 1];
  // Only minutes and seconds come next, each 60 to the unit above.
  if (next !== undefined && Math.abs(parts[next]) * 2 >= 60) value += parts[next] > 0 ? 1 : -1;
  const shifted = add(date, largest.unit, -value);
  const carried = nonZeroParts(shifted, date, relativeUnits)[0];
  return carried !== undefined && carried.unit !== largest.unit ? carried : { unit: largest.unit, value };
}

// The largest unit apart counted from the start of the reference's `unit`, or its end for an
// earlier date, so that a time on the day before reads "yesterday" however few hours ago.
function aligned(reference, date, unit) {
  const [start, end] = interval(unit, reference);
  const edge = reference < date ? start : new Date(end.getTime() - 1000);
  return nonZeroParts(edge, date, relativeUnits)[0];
}

// The local day, week, month or year `date` is in, as its start and the next one's.
function interval(unit, date) {
  const y = date.getFullYear(), m = date.getMonth(), d = date.getDate();
  switch (unit) {
    case 'year': return [new Date(y, 0, 1), new Date(y + 1, 0, 1)];
    case 'month': return [new Date(y, m, 1), new Date(y, m + 1, 1)];
    case 'week': {
      const back = (date.getDay() - (firstWeekday - 1) + 7) % 7;
      return [new Date(y, m, d - back), new Date(y, m, d - back + 7)];
    }
    default: return [new Date(y, m, d), new Date(y, m, d + 1)];
  }
}

function nonZeroParts(from, to, units) {
  return partsBetween(from, to, units).filter(part => part.value !== 0);
}

// How far `to` is from `from` in each of `units`, largest first, each counted from where the
// larger ones left off, as Calendar.dateComponents(_:from:to:) counts.
function partsBetween(from, to, units) {
  let start = from;
  return units.map(unit => {
    const value = unitsBetween(start, to, unit);
    start = add(start, unit, value);
    return { unit, value };
  });
}

// The most whole `unit`s that can be added to `start` without passing `target`.
function unitsBetween(start, target, unit) {
  const forward = target >= start;
  const reaches = count => {
    const time = add(start, unit, count).getTime();
    return forward ? time <= target.getTime() : time >= target.getTime();
  };
  let within = 0, beyond = forward ? 1 : -1;
  while (reaches(beyond)) {
    within = beyond;
    beyond *= 2;
  }
  while (Math.abs(beyond - within) > 1) {
    const middle = within + Math.trunc((beyond - within) / 2);
    if (reaches(middle)) within = middle;
    else beyond = middle;
  }
  return within;
}

// `count` of `unit` added as Calendar adds them: days, weeks, months and years on the local
// calendar keeping the time of day, a month's day kept to its length; the rest as elapsed time.
function add(date, unit, count) {
  const y = date.getFullYear(), m = date.getMonth(), d = date.getDate();
  const time = [date.getHours(), date.getMinutes(), date.getSeconds(), date.getMilliseconds()];
  switch (unit) {
    case 'year': return inMonth(y + count, m, d, time);
    case 'month': return inMonth(y, m + count, d, time);
    case 'week': return new Date(y, m, d + 7 * count, ...time);
    case 'day': return new Date(y, m, d + count, ...time);
    case 'hour': return new Date(date.getTime() + count * 3_600_000);
    case 'minute': return new Date(date.getTime() + count * 60_000);
    default: return new Date(date.getTime() + count * 1000);
  }
}

function inMonth(year, month, day, time) {
  const first = new Date(year, month, 1);
  const length = new Date(first.getFullYear(), first.getMonth() + 1, 0).getDate();
  return new Date(first.getFullYear(), first.getMonth(), Math.min(day, length), ...time);
}
