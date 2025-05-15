/*
* jquery.dvvset
*
* Dotted Version Vector Sets
*
*/


(function($){

$.dvvset = function(options){
 var API = {
    _cmp_fun: function(a,b){
	if (typeof a === 'string' && typeof b === 'string') {
	    return a > b;
	}
	if (typeof a === 'number' && typeof b === 'number') {
	    return a > b;
	}
	if(Array.isArray(a) && Array.isArray(b)){
	    if(a.length > 0 && b.length > 0){
		if(Array.isArray(a[0]) && Array.isArray(b[0])){
		    return a[0].length > b[0].length;
		}
		if(Array.isArray(a[0])) return true;
	    }
	}
	if(Array.isArray(a) && !Array.isArray(b)) return true;
	if(Array.isArray(b)) return true;
	return (a.length > b.length);
    },
    reducer: function(prevValue, currentValue, currentIndex, arr){
      return API._sync(prevValue, currentValue);
    },
    foldl: function(acc, xs) {
      var xsclone = Array.from(xs);
      return xs.reverse().reduce(API.reducer, acc);
    },
    new_dvv: function(value){
      return [[], [value]];
    },
    new_list: function(value){
      if(value.constructor === Array){
	return [[], value];
      } else {
	return [[], [value]];
      }
    },
    /*
     * Allows to compare lists with strings, as in Erlang.
     * ( list > string )
     */
    new_with_history: function(vector, value){
      var vectors = vector.sort(API._cmp_fun);
      var entries = [];
      for(var i=0;i!=vectors.length;i++){
	var item = vectors[i];
	var i_value = item[0];
	var number = item[1];
	entries.push([i_value, number, []]);
      }
      return [entries, value];
    },
    new_list_with_history: function(vector, value){
      if(!Array.isArray(value)) return API.new_list_with_history(vector, [value]);
      return API.new_with_history(vector, value);
    },
    sync: function(clock){
      return API.foldl([], clock);
    },
    _sync: function(clock1, clock2){
      if(clock1.length==0) return clock2;
      if(clock2.length==0) return clock1;
      clock1_entires = clock1[0];
      clock1_values = clock1[1];
      clock2_entires = clock2[0];
      clock2_values = clock2[1];
      var values = new Array();
      if(API.less(clock1, clock2)){
	values = clock2_values
      } else {
	if(API.less(clock2, clock1)){
	  values = clock1_values
	} else {
	  var newset = new Set();
	  for(var i=0;i!=clock1_values.length;i++){
	    newset.add(clock1_values[i]);
	  }
	  for(var i=0;i!=clock2_values.length;i++){
	    newset.add(clock2_values[i]);
	  }
	  values = Array.from(newset);
	}
      }
      return [API._sync2(clock1_entires, clock2_entires), values];
    },
    _sync2: function(entries1, entries2){
      if(entries1.length==0) return entries2;
      if(entries2.length==0) return entries1;
      head1 = entries1[0];
      head2 = entries2[0];
      if(API._cmp_fun(head2[0], head1[0])){
	return [head1].concat( API._sync2(entries1.slice(0).splice(1, entries1.length), entries2) );
      }
      if(API._cmp_fun(head1[0], head2[0])) {
	return [head2].concat(API._sync2(entries2.slice(0).splice(1, entries2.length), entries1))
      }
      var to_merge = head1.concat([head2[1], head2[2]]);
      var result = API._merge(...to_merge);
      return [result].concat(API._sync2(entries1.slice(0).splice(1, entries1.length), entries2.slice(0).splice(1, entries2.length)));
    },
    /*
     * Returns [id(), counter(), values()]
     */
    _merge: function(the_id, counter1, values1, counter2, values2){
      var len1 = values1.length;
      var len2 = values2.length;
      if(counter1 >= counter2) {
	if(counter1 - len1 >= counter2 - len2) return [the_id, counter1, values1];
	return [the_id, counter1, values1.slice(0).splice(0, counter1 - counter2 + len2)];
      }
      if(counter2 - len2 >= counter1 - len1) return [the_id, counter2, values2];
      return [the_id, counter2, values2.slice(0).splice(0, counter2 - counter1 + len1)];
    },
    join: function(clock){
      values = clock[0]
      result = []
      for(var i=0;i!=values.length;i++){
	value = values[i];
	if(!value) continue;
	result.push([value[0], value[1]]);
      }
      return result;
    },
    create: function(clock, the_id){
      var values = clock[1];
      if(Array.isArray(values) && values.length > 0) values = clock[1][0];
      return [API.event(clock[0], the_id, values), []];
    },
    /*
     * Advances the causal history of the
     * first clock with the given id, while synchronizing
     * with the second clock, thus the new clock is
     * causally newer than both clocks in the argument.
     * The new value is the *anonymous dot* of the clock.
     * The first clock SHOULD BE a direct result of new/2,
     * which is intended to be the client clock with
     * the new value in the *anonymous dot* while
     * the second clock is from the local server.
     */
    update: function(clock1, clock2, the_id){
      // Sync both clocks without the new value
      var clock1_entries = [];
      if(clock1.length>0) clock1_entries = clock1[0]
      var dot = API._sync([clock1_entries, []], clock2);
      var clock = dot[0];
      var values = dot[1];
      // We create a new event on the synced causal history,
      // with the id I and the new value.
      // The anonymous values that were synced still remain.
      var clock_values;
      if(clock1.length>0) clock_values = clock1[1];
      if(Array.isArray(clock1[1])) clock_values = clock1[1][0];
      return [API.event(clock, the_id, clock_values), values];
    },
    event: function(vector, the_id, value){
      if(vector.length==0) return [[the_id, 1, [value]]];
      if( vector.length > 0 && vector[0].length > 0 && vector[0][0] == the_id ) {
	if(Array.isArray(value)){
	    var values = value.concat(vector[0][2]);
	} else {
	    var values = [value].concat(vector[0][2]);
	}
	return [[vector[0][0], vector[0][1]+1, values].concat(vector.slice(0).splice(1, vector.length))];
      }
      if(vector.length > 0 && vector[0].length > 0) {
	if(Array.isArray(vector[0][0]) || vector[0][0].length > the_id.length) {
	  return [[the_id, 1, [value]]].concat(vector);
	}
      }
      var itm = API.event(vector.slice(0).splice(1, vector.length), the_id, value);
      return [vector[0]].concat(itm);
    },
    size: function(clock){
      var result = 0;
      var entries = [];
      if(clock.length>0) entries = clock[0];
      for(var i=0;i!=entries;i++){
	var entry = entries[i];
	result += entry[2].length;
      }
      var values = [];
      if(clock.length>0) values = clock[1];
      return result + values.length;
    },
    ids: function(clock){
      var entries = clock[0];
      var result = [];
      for(var i=0;i!=entries.length;i++){
	result.push(entries[i][0]);
      }
      return result;
    },
    values: function(clock) {
      var lst = [];
      for(var i=0;i!=clock[0].length;i++){
	var entry = clock[0][i];
	var value = entry[2];
	if(value.length==0) continue;
	lst.push(value)
      }
      var flat_list = [];
      for(var i=0;i!=lst.length;i++){
	var sublist = lst[i];
	for(var j=0;j!=sublist.length;j++){
	  flat_list.push(sublist[j]);
	}
      }
      return clock[1].concat(flat_list);
    },
    /* Compares the equality of both clocks, regarding
     * only the causal histories, thus ignoring the values.
     */
    equal: function(clock1, clock2) {
      if(!Array.isArray(clock1)) throw "clock1 should be a list";
      if(!Array.isArray(clock2)) throw "clock2 should be a list";
      if(clock1.length() == 2 && clock2.length == 2) return API._equal2(clock1[0], clock2[0]) // DVVSet
      return API._equal2(clock1, clock2)
    },
    _equal2: function(vector1, vector2) {
      if(vector1.length==0 && vector2.length==0) return true;
      if(vector1.length > 0 && vector1[0].length > 0 && vector2.length > 0 && vector2[0].length > 0){
	if(vector1[0][0] == vector2[0][0]){
	  if(vector1[0] > 1 && vector2[0] > 1 && vector1[0][1] == vector2[0][1]){
	    if(vector1[0][2] == vector2[0][2]) return API._equal(vector1.slice(0).splice(1, vector1.length), vector2.slice(0).splice(1, vector2.length))
	  }
	}
      }
      return false;
    },
    _greater: function(vector1, vector2, strict){
      if(vector1.length==0 && vector2.length==0) return strict;
      if(vector2.length==0) return true;
      if(vector1.length==0) return false;
      if(vector1[0][0] == vector2[0][0]){
	var dot_number1 = vector1[0][1];
	var dot_number2 = vector2[0][1];
	if(dot_number1 == dot_number2){
	  return API._greater(vector1.slice(0).splice(1, vector1.length), vector2.slice(0).splice(1, vector2.length), strict);
	}
	if(dot_number1 > dot_number2) {
	  return API._greater(vector1.slice(0).splice(1, vector1.length), vector2.slice(0).splice(1, vector2.length), true);
	}
	if(dot_number1 < dot_number2) return false;
      }
      if(API._cmp_fun(vector2[0][0], vector1[0][0])) return API._greater(vector1.slice(0).splice(1, vector1.length), vector2, true);
      return false;
    },
    /*
     * Returns True if the first clock is causally older than
     * the second clock, thus values on the first clock are outdated.
     * Returns False otherwise.
     */
    less: function(clock1, clock2){
      return API._greater(clock2[0], clock1[0], false);
    }
 };
 return {
    create: API.create,
    new_dvv: API.new_dvv,
    new_list: API.new_list,
    event: API.event,
    new_with_history: API.new_with_history,
    new_list_with_history: API.new_list_with_history,
    sync: API.sync,
    join: API.join,
    update: API.update,
    values: API.values,
    equal: API.equal,
    less: API.less
 };
};
})(jQuery);
