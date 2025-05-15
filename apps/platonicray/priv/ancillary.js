/*
* This file contains functions that are used in administrative interface only.
*/
function prevent_submit(e){
    var key;
    if(window.event) key = window.event.keyCode;
    else key = e.which;
    if(key == 13) return false;
}

var isMobile = {
    Android: function() {
        return navigator.userAgent.match(/Android/i);
    },
    BlackBerry: function() {
        return navigator.userAgent.match(/BlackBerry/i);
    },
    iOS: function() {
        return navigator.userAgent.match(/iPhone|iPad|iPod/i);
    },
    Opera: function() {
        return navigator.userAgent.match(/Opera Mini/i);
    },
    Windows: function() {
        return navigator.userAgent.match(/IEMobile/i);
    },
    any: function() {
        return (isMobile.Android() || isMobile.BlackBerry() || isMobile.iOS() || isMobile.Opera() || isMobile.Windows());
    }
}

function request(url, method, data, token, onSuccess, onFailure){
    $.ajax({
	url: url,
	type: method,
	cache: false,
	dataType: 'json',
	data: JSON.stringify(data),
	processData: false,
	contentType: false,
	timeout: 480000,
	headers: {'Content-Type': 'application/json'},
	success: function(data, status, jqXHR){
	    onSuccess(data, status, jqXHR)
	},
	beforeSend: function (xhr) {
	    xhr.setRequestHeader("authorization", "Token "+token);
	}
    }).fail(function(xhr, status, msg){
	onFailure(xhr, status, msg);
    });
}

function guid() {
  var fourth_group = ["8", "9", "a", "b"];
  var randomIndex = Math.floor(Math.random() * fourth_group.length);
  var string_to_replace="10000000-1000-4000-"+(fourth_group[randomIndex])+"000-100000000000";
  return string_to_replace.replace(/[018]/g, c =>
    (+c ^ crypto.getRandomValues(new Uint8Array(1))[0] & 15 >> +c / 4).toString(16)
  );
}
