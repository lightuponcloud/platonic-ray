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

function pad(number,length) {
    var str = '' + number;
    while (str.length < length) str = '0' + str;
    return str;
}

function unhex(obj_name){
 var bits = obj_name.split('/');
 for (var i=0, l=bits.length; i < l; i+=1){
  var chars="";
  var a=1;
  for (var j=0, cl = bits[i].length; j < cl; j += 2) {
    chars += '%'+bits[i].substring(j, j + 2);
  }
  try{
   bits[i] = decodeURIComponent(chars);
  } catch (e){
   if(e instanceof URIError) continue;
   throw e;
  }
 }
 return bits.join('/');
}

function get_query(a){
 a = a.substr(1).split('&');
 if (a == "") return {};
 var b = {};
 for (var i = 0; i < a.length; ++i){
  var p=a[i].split('=', 2);
  if (p.length == 1)
   b[p[0]] = "";
  else
   b[p[0]] = decodeURIComponent(p[1].replace(/\+/g, " "));
 }
 return b;
}

function decodeBase64(s) {
    var e={},i,b=0,c,x,l=0,a,r='',w=String.fromCharCode,L=s.length;
    var A="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    for(i=0;i<64;i++){e[A.charAt(i)]=i;}
    for(x=0;x<L;x++){
        c=e[s.charAt(x)];b=(b<<6)+c;l+=6;
        while(l>=8){((a=(b>>>(l-=8))&0xff)||(x<(L-2)))&&(r+=w(a));}
    }
    return r;
}

function display_objects(lstEl, brEl, hex_prefix, data, stack, embedded){
    var files=[];
    var directories=[];
    var root_uri=$('body').attr('data-root-uri');
    var bucket_id=$('body').attr('data-bucket-id');
    var static_root=stack.get_static_root();
    var prefix='';
    if(hex_prefix){
      prefix = unhex(hex_prefix);
      var bits = prefix.split('/');
      var emptyElidx = bits.indexOf("");
      if(emptyElidx!=-1){ bits.splice(emptyElidx, 1);}
      var hex_bits = hex_prefix.split('/');
      emptyElidx = hex_bits.indexOf("");
      if(emptyElidx!=-1) hex_bits.splice(emptyElidx, 1);
      var breadcrumbs = [];
      for(var i=0;i!=bits.length;i++){
	var part_prefix = hex_bits.slice(0, i+1).join('/');
	breadcrumbs.push({'part': bits[i], 'prefix': part_prefix});
      }
      $(brEl).empty();
      if(embedded){
        $(brEl).append('<a href="#" data-prefix="" class="dialog-bc-file-link">Root</a>');
      }else{
	$(brEl).append('<a href="'+root_uri+bucket_id+'/">Root</a>');
      }
      if(breadcrumbs.length>5){
	$(brEl).append('<span class="dirseparator"></span><span class="short">* * *</span>');
	breadcrumbs = breadcrumbs.slice(Math.max(breadcrumbs.length - 5, 1));
      }
      for(var i=0;i!=breadcrumbs.length-1;i++){
	var url = root_uri+bucket_id+'/?prefix='+breadcrumbs[i]['prefix'];
	var part_name = breadcrumbs[i]['part'];
	if(embedded){
	  $(brEl).append('<span class="dirseparator"></span><a href="#" class="dialog-bc-file-link" data-prefix="'+breadcrumbs[i]['prefix']+'">'+part_name+'</a>');
	}else{
	  $(brEl).append('<span class="dirseparator"></span><a href="'+url+'">'+part_name+'</a>');
	}
      }
      $(brEl).append('<span class="dirseparator"></span><span class="current">'+bits[bits.length-1]+'</span>');
      var prev_prefix = '';
      if(bits.length>1){
	var prev_prefix = hex_bits.slice(0, hex_bits.length-1).join('/');
      }
      directories.push({'name': '..', 'prefix': prev_prefix});
    }else{
      $(brEl).empty();
      if(embedded){
        $(brEl).append('<a href="#" data-prefix="" class="dialog-bc-file-link">Root</a>');
      }else{
	$(brEl).append('<a href="'+root_uri+bucket_id+'/">Root</a><span class="dirseparator"></span>');
      }
    }
    $(data.dirs).each(function(i,v){
      if(v.is_deleted) return true;
      var dir_name = v.prefix;
      if(hex_prefix) {
	dir_name = dir_name.replace(hex_prefix, '');
      }
      if(dir_name.indexOf('/')==0) dir_name = dir_name.substring(1, dir_name.length);
      directories.push({'name': dir_name, 'prefix': hex_prefix, 'guid': guid()});
    });
    var dvvset = $.dvvset();
    $(data.list).each(function(i,v){
      if(v.is_deleted) return true;
      var version = JSON.parse(decodeBase64(v.version));
      var values = dvvset.values(version);
      var date = values[0];
      var name = v.object_key;
      var orig_name = v.orig_name;
      if(!embedded){
       files.push({
	'name': name,
	'modified': date,
	'orig_name': orig_name,
	'short_url': v.short_url,
	'preview_url': v.preview_url,
	'public_url': v.public_url,
	'ct': v.content_type,
	'bytes': v.bytes,
	'guid': v.guid,
        'version': v.version,
	'is_locked': v.is_locked,
	'lock_modified_utc': v.lock_modified_utc,
	'lock_user_name': v.lock_user_name,
	'lock_user_tel': v.lock_user_tel,
        'width': v.width,
        'height': v.height
       });
      }
    });
    directories.sort();
    $(directories).each(function(i,v){
     var name = unhex(v.name);
     if(name.charAt(0)=="/") name=name.substr(1);
     var button='<div class="file-menu"><a class="menu-link" href="#" data-obj-n="'+encodeURIComponent(v.name)+'">Action<span>&#9660;</span></a></div>';
     var input='';
     var uri=root_uri+bucket_id+'/';
     var eff_prefix=v.prefix;
     if(v.name!='..'){
	if(hex_prefix){
	 eff_prefix = (hex_prefix.charAt(hex_prefix.length-1)=='/'?hex_prefix:hex_prefix+'/')+v.name;
	} else {
	 eff_prefix = v.name;
	}
     } else {
	eff_prefix = v.prefix;
     }
     uri+='?prefix='+eff_prefix;
     var flink='<div class="file-name"><a title="'+(name=='..'?'Parent Directory':name)+'" class="file-link folder" href="'+uri+'"><i class="folder-icon"></i>'+name+'</a></div>';
     var fsize='<div class="file-size" data-bytes="0">&nbsp;</div>';
     if(embedded){
      button='';
      flink='<div class="dialog-file-name" data-prefix="'+eff_prefix+'"><a title="'+name+'" class="dialog-file-link folder" href="#" data-prefix="'+eff_prefix+'"><i class="folder-icon"></i>'+name+'</a></div>';
      fsize='';
     }
     $(lstEl).append('<div class="file-item dir '+(name=='..'?'parent-dir ':'')+'" style="display:block;" id="'+v.guid+'">'+flink+fsize+'<div class="file-modified">&nbsp;</div><div class="file-preview-url"></div><div class="file-url"></div>'+(name=='..'?'<div class="file-menu"></div>':button)+'</div>');
    });
    files.sort();
    $(files).each(function(i,v){
     var name = v.orig_name;
     var obj_name = v.name;
     var fsize = filesize(v.bytes);
     var url = stack.get_download_url(root_uri, bucket_id, hex_prefix, obj_name);
     if(prefix) name = name.replace(prefix, '');
     var button='<div class="file-menu"><a class="menu-link" href="#" data-obj-n="'+encodeURIComponent(obj_name)+'" data-obj-url="'+url+'" data-obj-preview-url="'+v.preview_url+'" data-obj-pub-url="'+url+'">Action<span>&#9660;</span></a></div>';
     var input='';
     var d=new Date(parseInt(v.modified)*1000);
     var modified=pad(d.getDate(), 2)+'.'+pad(d.getMonth()+1,2)+'.'+d.getFullYear()+' '+pad(d.getHours(),2) + "." + pad(d.getMinutes(), 2);
     if(embedded) button='';
     var gid=v.guid;
     var lock_tel=(v.lock_user_tel==undefined?'':'. Tel: '+v.lock_user_tel);
     var thumb_url='/riak/thumbnail/'+bucket_id+'/?prefix='+(hex_prefix+""=="NaN"?'':hex_prefix)+'&object_key='+decodeURIComponent(obj_name);
     var pswp_width=v.width;
     var pswp_height=v.height;
     if(v.width+""!="NaN"){
         var maxWidth = 1024;
         var maxHeight = 768;
         var ratio = 0;
         if(v.width>maxWidth){
            ratio = maxWidth / v.width;
            pswp_height = Math.trunc(v.height * ratio);
            pswp_width = Math.trunc(v.width * ratio);
         }
         if(v.height > maxHeight){
            ratio = maxHeight / v.height;
            pswp_width = Math.trunc(v.width * ratio);
            pswp_height = Math.trunc(v.height * ratio);
         }
         if(v.bytes<=563200&&v.width<maxWidth&&v.height<maxHeight){
           thumb_url=url;
         } else {
           thumb_url+="&w="+pswp_width+"&h="+pswp_height;
       }
     }
     var anchor='<a title="'+name+'"  class="file-link" href="#"><i class="doc-icon"></i>'+name+'</a>';
     if(v.ct.substring(0, 5)=='image'){
       anchor='<a title="'+name+'" data-pswp-width="'+pswp_width+'" data-pswp-height="'+pswp_height+'" class="file-link gallery" href="'+thumb_url+'"><i class="doc-icon"></i>'+name+'</a>';
     } else if(v.ct=='"application/pdf"'){
       anchor='<a title="'+name+'" data-pswp-width="700" data-pswp-height="600" class="file-link gallery" href="'+url+'"><i class="doc-icon"></i>'+name+'</a>';
     }

     var ve = $(lstEl).append('<div class="file-item clearfix" id="'+gid+'">'+input+'<div class="file-name" id="'+v.version+'">'+anchor+'</div><div class="file-size" data-bytes="'+v.bytes+'">'+fsize+'</div><div class="file-modified">'+modified+'</div><div class="file-preview-url">'+(v.is_locked==true?'<img src="'+static_root+'lock.png" title="'+v.lock_user_name+lock_tel+'"/>':'&nbsp;')+'</div><div class="file-url"><a href="'+url+'">link</a></div>'+button+'</div>');
     if(v.ct.substring(0, 5)=='image'||v.ct.substring(0, 5)=='video'){
	$(ve).find('div#'+gid).find('.doc-icon').css('background-image', 'url("/riak/thumbnail/'+bucket_id+'/?prefix='+(hex_prefix+""=="NaN"?'':hex_prefix)+'&object_key='+decodeURIComponent(obj_name)+'&w=50&h=50")');
     }
    });
}

function fetch_file_list(bucket_id, hex_prefix, msgEid, targetE, embedded){
  var root_uri=$('body').attr('data-root-uri');
  var bucket_id=$('body').attr('data-bucket-id');

  var stack = $.stack({'errorElementID': msgEid, 'loadingMsgColor': 'black', 'rpc_url': root_uri+'list/'+bucket_id+'/', 'onSuccess': function(data, status){
    $('#'+msgEid).empty();
    if(isMobile.any() || $(window).width()<670){
	$('#shadow').empty().hide();
    }else{
	$('.loading-message-wrap').hide();
    }
    var lst = $('#'+targetE);
    $(lst).empty();
    var directories=[];
    if(hex_prefix){
      var slash=hex_prefix.match(/\//g);
      var prev=(hex_prefix+'/').split('/', (slash==null?0:slash.length-1)).join('/');
      directories.push({'name': '..', 'modified': '', 'prefix': (prev==''?'':prev+'/')});
    }
    if(!embedded){
     display_objects(lst, $('#id-block-header'), hex_prefix, data, stack, false);
     enable_menu_item('menu-createdir');
     enable_menu_item('menu-actionlog');
     refreshMenu();
    }else{
     display_objects(lst, $('#id-dialog-block-header'), hex_prefix, data, stack, true);
    }
    $('.files-tbl').show();
    if($(window).width()<670) {
	$(".file-link").width($('.file-item').width());
    }
  }, 'onFailure': function(msg, s1, s2){
    $('#'+msgEid).empty();
    $('#'+msgEid).append('<span class="err">'+msg+'</span>');
  }});
  stack.get_objects_list(hex_prefix);
}

function menuHack(e){
    var i = decodeURIComponent($(e).attr('data-obj-n'));
    var lid = $(e).parent().parent().attr('id');
    var surl = $(e).attr('data-obj-url');
    var purl = $(e).attr('data-obj-pub-url');
    var rurl = $(e).attr('data-obj-preview-url');
    $("#context-menu").attr('data-obj-n', i);
    $("#context-menu").attr('data-line-id', lid);
    $("#context-menu").attr('data-obj-url', surl);
    $("#context-menu").attr('data-obj-preview-url', rurl);
    $("#context-menu").attr('data-obj-pub-url', purl);
    if(rurl){
      $("#context-menu").attr('data-obj-preview-url', rurl);
    } else {
      rurl = i;
    }
    if(purl) $("#context-menu").attr('data-obj-pub-url', purl);
    if(!surl) $('span#menu-copy-link').parent().replaceWith('<span class="lsp"><span id="menu-copy-link"><span>Copy Link</span></span></span>');
    if(!($(e).parent().parent().hasClass('dir'))){
	$("#menu-open span").text('Download');
	if($('#menu-preview').length==0&&isMobile.any()){
	  $("#menu-open").parent().parent().parent().append('<div class="row"><a href="'+rurl+'"><span id="menu-preview"><span>Preview</span></span></a></div>');
	  $('#menu-preview').click(function(){
	    $("#context-menu").hide();
	    $(".menu-link").hide();
	    $("#shadow").hide();
	    document.location = $(this).attr("href");
	  });
	}
    } else {
	$("#menu-open span").text('Open');
	if(isMobile.any()) $('#menu-preview').remove();
    }
}

function refreshMenu(){
 $(".file-size, .file-modified").click(function(){
  var href = $(this).parent().find(".file-link").attr('href');
  if(href!='#') document.location=href;
 });
 if(isMobile.any() || $(window).width()<670){
  $(".file-item").off('click');
  $(".file-item").on('click', function(e){
    $(".file-item").removeClass("current");
    var el = $(this).find(".menu-link")[0];
    menuHack(el);
    var Fname = $(this).find(".menu-link").attr('data-obj-n');
    Fname = Fname.replace(/%20/g," ")
    if($("#context-menu").css('display') != 'block'){
	$(this).addClass("current");
	var lnk = $(this).find(".menu-link").attr('data-obj-pub-url');
	if(lnk == '#' || typeof lnk == 'undefined') lnk = $(this).find(".file-link").attr('href');
	var plnk = $(this).find(".menu-preview-link").attr('data-obj-preview-url');
	if(plnk == '#' || typeof plnk == 'undefined') plnk = $(this).find(".file-link").attr('href');
	$("#context-menu .open-link a").attr("href", lnk);
	$("#context-menu .open-preview-link a").attr("href", plnk);
	$("#context-menu .menu-head").find('span').text(Fname);
        $("#context-menu").show();
	$("#shadow").show();
    }
    return false; 
  });

  $("#context-menu .menu-head a").click(function(){
    $("#context-menu").hide();
    $("#shadow").hide();
    return false;
  });
 }else{
  $(".file-menu a").off('click');
  $(".file-menu a").on('click', function(e){
    menuHack(this);
    if($("#context-menu").css('display') == 'block'){
        $("#context-menu").hide();
    }else{
        var topPos = $(this).offset().top - $(".management-block").offset().top + 30;
        var leftPos = $(this).offset().left  - $('.management-table').offset().left;
        $("#context-menu").css({top: topPos+'px',left: leftPos+'px'});
        $("#context-menu").show();
    }
    return false; 
  });
 }
 $(".file-item").hover(
    function(){
	if($("#context-menu").css('display') != 'block'){
	    $(this).find('.menu-link').show().css('display','inline-block');
	    $(this).closest('div.file-item').addClass('current');
	}
    },
    function(){
	if($("#context-menu").css('display') != 'block'){
	    $(this).find('.menu-link').hide();
	    $(this).closest('div.file-item').removeClass('current');
	}
    }
 );
 $('#context-menu a').click(function(e){
    $("#context-menu").hide();
    $(".menu-link").hide();

    var op=$(this).find('span').first().attr('id');
    var on=decodeURIComponent($(this).parent().parent().attr('data-obj-n'));
    var lid=$("#context-menu").attr('data-line-id');
    var surl=$(this).parent().parent().attr('data-obj-url');
    var purl=$(this).parent().parent().attr('data-obj-pub-url');
    var bucket_id = $("body").attr("data-bucket-id");
    var hex_prefix  = $("body").attr("data-hex-prefix");
    var root_uri=$('body').attr('data-root-uri');
    var orig_name=$('div#'+lid).find('div.file-name').find('a').attr('title');

    if(op=='menu-copy'){
	copy_dialog(this, on, orig_name, false);
	return false;
    } else if(op=='menu-rename'){
	rename_dialog(this, on, orig_name);
    } else if(op=='menu-changelog'){
	changelog_dialog(this, on, orig_name);
    } else if(op=='menu-lock'){
	lock_action(this, on);
    } else if(op=='menu-move'){
	copy_dialog(this, on, orig_name, true);
	return false;
    } else if(op=='menu-open'){
	$("#shadow").hide();
	document.location = $(this).attr('href'); //'/'+surl;
    }else if(op=='menu-delete'){
	var msg='file';
	if($('#'+lid).hasClass('dir')) msg='directory';
	$('#id-dialog-obj-rm-msg').empty().append(msg+' <br/><b>'+orig_name+'</b>?');
	$(".confirm").show();
	$("#shadow").show();
	$(".current").addClass("deleting");

	$("#ok-btn").off('click');
	$("#ok-btn").unbind('click').click(function(){
    	    var lid=$("#context-menu").attr('data-line-id');
	    $(".confirm").hide();
	    $("#shadow").hide();

	    $('#'+lid).find('.menu-link').remove();
	    if($('#'+lid).hasClass('dir')){
		$('#'+lid).addClass('inactive');
	    }
	    var stack = $.stack({'errorElementID': 'id-status', 'rpc_url': root_uri+'list/'+bucket_id+'/', 'onSuccess': function(data){
		$('#'+lid).remove();
		$('#id-status').empty();
	    }, 'onFailure': function(msg, xhr, e){
	        $('#'+lid).removeClass('inactive');
	        $('#id-status').empty();
		if(msg&&msg.hasOwnProperty('error')){
		    $('#id-status').append('<span class="err">'+gettext(msg['error'])+'</span>');
		} else {
		    $('#id-status').append('<span class="err">Something\'s went horribly wrong</span>');
		}
	    }});
	    var bits = decodeURIComponent($("#context-menu").attr('data-obj-n'));
	    if(bits[bits.length-1]=="/"){
		bits = bits.split("/");
		bits[bits.length-2] += "/";
		bits.splice(-1);
	    }else{
		bits = bits.split("/");
	    }
	    stack.delete_object(hex_prefix, [bits[bits.length-1]]);
	    return false;
	});
	$("#cancel-btn").unbind('click').click(function(){
	    $(".confirm").hide();
	    $("#shadow").hide();
	    $(".file-item").removeClass("deleting");
	    return false;
	});
	$('.deleting a').click(function(e){
	    e.preventDefault();
	    return false;
	});
    } else if(op=='menu-copy-link'){
     var link_d = '<input type="text" id="id-link-cppy" value="/'+surl+'" name="linkcopy">';
     $("#dialog").dialog({
      title: 'Short Link',
      resizable: false,
      height: 'auto',
      width:'300',
      position: [($(window).width() / 2) - (600 / 2), 150],
      modal: true,
      draggable: false,
      open: function (event, ui) {
       $(this).empty().append(link_d).find('#id-link-copy').select();
      },
      close: function (event, ui) {
        event.stopPropagation();
        event.preventDefault();
        $(this).dialog("close");
      }
     });
     $("#dialog").dialog('open');
    }
    return false;
 });
}


function copy_dialog(e, from_object_key, orig_name, to_move){
 var bucket_id = $("body").attr("data-bucket-id");
 var copy_form = '<form method="POST" id="id-copy-form" name="copy_form" > \
<input type="hidden" name="hex_prefix" id="id-dialog-prefix" value="'+$('body').attr('data-hex-prefix')+'"> \
<h3><span id="id-dialog-block-header"></span></h3> \
<div class="files-tbl clearfix"><div class="files-tbl_th"> \
<div class="file-name_th"><a href="#" id="id-dialog-sort-by-name" data-sorting="asc">Name</a></div> \
<div class="file-size_th"><a href="#" id="id-dialog-sort-by-size" data-sorting="asc">Size</a></div> \
<div class="file-modified_th"><a href="#" id="id-dialog-sort-by-date" data-sorting="asc">Modified</a></div> \
<div></div></div><div id="id-dialog-objects-list"></div></div> \
<br/><br/><span id="id-copy-distination"></span>&nbsp;&nbsp; \
<span class="pushbutton"><button type="button" class="form-short-small-button2" id="id-dialog-submit-copy">'+(to_move==true?'Move':'Copy')+'</button></span> \
<span id="id-dialog-loading-message-text"></span>';

 var title='Copy '+orig_name+'. Chose Destination Directory';
 if(to_move){
  title='Move '+orig_name+'. Chose Destination Directory';
 }
 $("#dialog").dialog({
  title: title,
  autoOpen: false,
  resizable: false,
  height: 'auto',
  width:'600',
  position: [($(window).width() / 2) - (600 / 2), 150],
  modal: true,
  draggable: false,
  open: function (event, ui) {
   $(this).empty().append(copy_form);
   $('#id-block-header *').clone().appendTo($('#id-dialog-block-header'));
   $('#id-dialog-block-header a').each(function(i,v){
    var url=$(v).attr('href');
    var urlparts=url.split('?');
    if(urlparts.length==1){
	$(v).addClass('dialog-bc-file-link');
	$(v).attr('href', "#");
	$(v).attr('data-prefix', "");
	return true;
    }
    var bits=urlparts[1].split('&');
    for (i=0;i<bits.length;i++) {
      var param=bits[i].split('=');
      if(param[0]=='prefix'){
	$(v).attr('data-prefix', param[1]);
	break;
      }
    }
    $(v).attr('href', '#');
    $(v).addClass('dialog-bc-file-link');
   });
   $('#id-dialog-block-header').find('.current').css('color', 'black');
   $('#id-objects-list div.file-item').each(function(i,v){
    if($(v).hasClass('inactive')||!$(v).hasClass('dir')) return false;
    $(v).clone().appendTo($('#id-dialog-objects-list'));
   });
   $('#id-dialog-objects-list').show();
   $('#id-dialog-objects-list').find('div.file-menu').remove();
   $('#id-dialog-objects-list').find('div.file-size').remove();
   $('#id-dialog-objects-list').find('div.file-url').remove();
   $('#id-dialog-objects-list').find('div.file-preview-url').remove();
   $('#id-dialog-objects-list').parent().find('div.file-size_th').remove();
   $('#id-dialog-objects-list .file-item').each(function(i,v){
    var fn=$(v).find('.file-name');
    var args=get_query($(v).find('.file-link')[0].search);
    var prefix=args.prefix;
    $(v).find('.file-link').attr('data-prefix', prefix);
    $(v).find('.file-link').attr('href', '#');
    $(v).find('.file-link').removeClass('file-link').addClass('dialog-file-link');
    $(v).find('.file-name').removeClass('file-name').addClass('dialog-file-name');
    $(v).attr('id', guid());
   });
   $("#id-dialog-objects-list").off('click').on('click', '.dialog-file-name', function(e){
    var hex_prefix=$(this).find('a.dialog-file-link').attr('data-prefix');
    $('#id-dialog-prefix').val(hex_prefix);
    $('#id-dialog-block-header .current').empty();
    fetch_file_list(bucket_id, hex_prefix, 'id-dialog-loading-message-text', 'id-dialog-objects-list', true);
    return false;
   });
   $("#id-dialog-block-header").off('click').on('click', '.dialog-bc-file-link', function(e){
    var hex_prefix=$(this).attr('data-prefix');
    $('#id-dialog-prefix').val(hex_prefix);
    $('#id-dialog-block-header .current').empty();
    fetch_file_list(bucket_id, hex_prefix, 'id-dialog-loading-message-text', 'id-dialog-objects-list', true);
    return false;
   });
   if($(window).width()<670){
    $("#dialog").dialog("option", "width", 300);
    $("#dialog").dialog("option", "position", { my: "center", at: "center", of: window});
   }
   $(window).resize(function(){
       if($(window).width()<670){
	$("#dialog").dialog( "option", "width", 300 );
      }else{
	$("#dialog").dialog( "option", "width", 600 );
      }
      $("#dialog").dialog( "option", "position", { my: "center", at: "center", of: window });
   });
  },
  close: function (event, ui) {
    event.stopPropagation();
    event.preventDefault();
    $("#shadow").hide();
    $(this).dialog("close");
  }
 });
 $("#dialog").dialog('open');

 $('#id-dialog-submit-copy').unbind('click').click(function(){
  if($("#id-dialog-submit-copy")=="disabled") return false;
  $("#id-dialog-submit-copy").attr("disabled","disabled");
  $('#id-dialog-loading-message-text').empty();
  var root_uri=$('body').attr('data-root-uri');
  var src_bucket_id=$('body').attr('data-bucket-id');
  var src_hex_prefix=$('body').attr('data-hex-prefix');
  var dst_hex_prefix = $('#id-dialog-prefix').val();
  if(dst_hex_prefix==src_hex_prefix){
    $('#id-dialog-loading-message-text').empty().append('<br/><span class="err">Please select destination directory.</span>');
    $("#id-dialog-submit-copy").attr("disabled",false);
    return false;
  }
  var rpc_url = root_uri+'copy/'+bucket_id+'/';
  if(to_move) rpc_url = root_uri+'move/'+bucket_id+'/';
  var stack = $.stack({'errorElementID': 'id-dialog-loading-message-text', 'rpc_url': rpc_url, 'onSuccess': function(data){
    $('#id-dialog-loading-message-text').empty();
    $("#id-dialog-submit-copy").attr("disabled",false);
    $("#dialog").dialog('close');
    if(to_move) fetch_file_list(src_bucket_id, src_hex_prefix, 'id-loading-message-text', 'id-objects-list', false);
   }, 'onFailure': function(msg, xhr, status){
    $('#id-dialog-loading-message-text').empty().append('<br/><span class="err">'+msg+'</span>');
    $("#id-dialog-submit-copy").attr("disabled",false);
   }
  });

  stack.copy_object(src_bucket_id, src_hex_prefix, from_object_key, orig_name, src_bucket_id, dst_hex_prefix, from_object_key);
//  var objects=[[src_hex_prefix, from_object_key]];
// TODO: to check status of copied objects
  return false;
 });
 return false;
}

function submit_rename(bucket_id, hex_prefix, from_object_key, is_dir){
    $('#id-dialog-loading-message-text').empty();
    $('#id_object_name_errors').empty();
    $("#submit_rename").attr("disabled","disabled");
    if(isMobile.any() || $(window).width()<670){$("#shadow").append('<span>Two moments please...</span>').css('z-index','1003').show();}
    disable_menu_item('menu-rename');

    if(is_dir){
      var vresult = validate_dirname($('#id_object_name').val(), $('#id_object_name_errors'), function(){});
      if(!vresult){
	$('#submit_rename').attr("disabled", false);
	return false;
      }
    }
    var root_uri=$('body').attr('data-root-uri');
    var dst_object_name = $('#id_object_name').val();
    var rpc_url = root_uri+'rename/'+bucket_id+'/';
    var stack = $.stack({'errorElementID': 'id-status', 'rpc_url': rpc_url, 'onSuccess': function(data){
	$('#id-status').empty();
	$("#shadow").empty().css('z-index', 9).hide();
	$('#id_rename').attr("disabled", false);
	fetch_file_list(bucket_id, hex_prefix, 'id-loading-message-text', 'id-objects-list', false);
	enable_menu_item('menu-rename');
	$('.ui-dialog-titlebar-close').click();
	$('#id-status').empty();
	$('#submit_rename').attr("disabled", false);
	fetch_file_list(bucket_id, hex_prefix, 'id-loading-message-text', 'id-objects-list', false);
    }, 'onFailure': function(msg, xhr, status){
	$('#id-dialog-loading-message-text').empty().append('<br/><span class="err">'+msg+'</span>');
	$("#submit_rename").attr("disabled",false);
    }});
    stack.rename_object(hex_prefix, from_object_key, dst_object_name);
    // TODO: to check status of renamed object
}

function rename_dialog(e, from_object_key, orig_name){
 var bucket_id = $("body").attr("data-bucket-id");
 var hex_prefix=$('body').attr('data-hex-prefix');
 var is_dir = from_object_key.indexOf('/') == from_object_key.length-1;
 var rename_form = '<form method="POST" id="id-rename-form" name="rename_form" > \
<input type="hidden" name="hex_prefix" id="id-dialog-prefix" value=""> \
<h3><span id="id-dialog-block-header"></span></h3> \
<br/><input name="object_key" id="id_object_name" style="width:558px" value="'+
(orig_name.charAt(orig_name.length-1)=='/'?orig_name.slice(0, orig_name.length-1):orig_name)+'" autofocus/><br/> \
<div><div style="float:left;margin-top:14px;"><span class="err" id="id_object_name_errors"></span></div> \
<div style="float:right;padding-top:10px;margin-right:4px;"> \
<span class="pushbutton"><button type="button" class="form-short-small-button2" id="submit_rename">Submit</button></span> \
<span id="id-dialog-loading-message-text"></span></div></div>';

 $("#dialog").dialog({
  title: 'Rename "'+orig_name+'"',
  autoOpen: false,
  resizable: false,
  height: 'auto',
  width:'600',
  position: [($(window).width() / 2) - (600 / 2), 150],
  modal: true,
  draggable: false,
  open: function (event, ui) {
   $(this).empty().append(rename_form);
   $('#id-dialog-block-header').find('.current').css('color', 'black');
   if($(window).width()<670){
    $("#dialog").dialog("option", "width", 300);
    $("#dialog").dialog("option", "position", { my: "center", at: "center", of: window});
   }
   $(window).resize(function(){
       if($(window).width()<670){
	$("#dialog").dialog( "option", "width", 300 );
      }else{
	$("#dialog").dialog( "option", "width", 600 );
      }
      $("#dialog").dialog( "option", "position", { my: "center", at: "center", of: window });
   });
  },
  close: function (event, ui) {
    event.stopPropagation();
    event.preventDefault();
    $("#shadow").hide();
    $(this).dialog("close");
  }
 });
 $("#dialog").dialog('open');
 $('#id_object_name').focus();
 $('#id_object_name').unbind('keydown').keydown(function(e){
    var key;
    if(window.event) key = window.event.keyCode;
    else key = e.which;
    if(key == 13) return false;
 });
 $('#id_object_name').unbind('keyup').keyup(function(e){
    var key;
    if(window.event) key = window.event.keyCode;
    else key = e.which;
    if(key == 13) {
      $('#submit_rename').click();
    }
 });
 $('#submit_rename').unbind('click').click(function(e){
    if($('#submit_rename').attr("disabled") == "disabled") return false;
    $('#submit_rename').attr("disabled", "disabled");
    submit_rename(bucket_id, hex_prefix, from_object_key, is_dir);
    return false;
 });
 return false;
}


function submit_restore(bucket_id, hex_prefix, object_key, last_modified_utc){
    $('#id-dialog-loading-message-text').empty();
    if(isMobile.any() || $(window).width()<670){$("#shadow").append('<span>Two moments please...</span>').css('z-index','1003').show();}
    disable_menu_item('menu-changelog');

    var root_uri=$('body').attr('data-root-uri');
    var rpc_url = root_uri+'action-log/'+bucket_id+'/';
    var stack = $.stack({'errorElementID': 'id-status', 'rpc_url': rpc_url, 'onSuccess': function(data){
	$('#id-status').empty();
	$("#shadow").empty().css('z-index', 9).hide();
	$('#id-restore_'+last_modified_utc).attr("disabled", false);
	fetch_file_list(bucket_id, hex_prefix, 'id-loading-message-text', 'id-objects-list', false);
	enable_menu_item('menu-changelog');
	$('.ui-dialog-titlebar-close').click();
	$('#id-status').empty();
	$('#id-restore_'+last_modified_utc).attr("disabled", false);
	fetch_file_list(bucket_id, hex_prefix, 'id-loading-message-text', 'id-objects-list', false);
    }, 'onFailure': function(msg, xhr, status){
	$('#id-dialog-loading-message-text').empty().append('<br/><span class="err">'+msg+'</span>');
	$('#id-restore_'+last_modified_utc).attr("disabled", false);
    }});
    stack.restore_object(object_key, last_modified_utc);
    // TODO: to check status
}

function lock_action(e, object_key){
 var bucket_id = $("body").attr("data-bucket-id");
 var root_uri=$('body').attr('data-root-uri');
 var hex_prefix=$("body").attr("data-hex-prefix");
 var stack = $.stack({
       'errorElementID': "id-status",
       'loadingMsgColor': 'black',
       'rpc_url': root_uri+'list/'+bucket_id,
       'onSuccess': function(data, status){
           $('#id-dialog-loading-message-text').hide();
        }
    });
    stack.lock(hex_prefix, object_key);
}

function changelog_dialog(e, object_key, orig_name){
 var bucket_id = $("body").attr("data-bucket-id");
 var root_uri=$('body').attr('data-root-uri');
 var hex_prefix=$("body").attr("data-hex-prefix");
 $("#dialog").dialog({
  title: '"'+object_key+'" changelog',
  autoOpen: false,
  resizable: false,
  height: 'auto',
  width:'600',
  position: [($(window).width() / 2) - (600 / 2), 150],
  modal: true,
  draggable: false,
  open: function (event, ui) {
    $(this).empty().append('<br/><div><span id="id-dialog-loading-message-text"></span><div id="id-dialog-changelog-records"></div>');
    var stack = $.stack({
       'errorElementID': "id-dialog-loading-message-text",
       'loadingMsgColor': 'black',
       'rpc_url': root_uri+'action-log/'+bucket_id+'/?prefix='+hex_prefix+'&object_key='+object_key,
       'onSuccess': function(data, status){
	   if(data.length==0){
	    $('#id-dialog-changelog-records').empty().append("<br/><br/><center><b>No changes were recorded yet.</b></center><br/><br/>");
            $('#id-dialog-loading-message-text').hide();
	    return;
	   }
           $('#id-dialog-changelog-records').append('<div class="dry-data-container"><table class="dry-data-table" cellpadding="0" cellspacing="0"><thead><tr class="first-row"><th class="first-col" style="width:33%;">Date</th><th class="last-col" style="width:33%;">User</th><th class="last-col" style="width:33%;">&nbsp;</th></tr></thead><tbody id="id-dialog-changelog-records-tbody"></tbody></table></div>');
           for(var i=0;i!=data.length;i++){
               var author=data[i].author_name;
	       var tel=data[i].author_tel;
               var dt=data[i].last_modified_utc;
               var d=new Date(dt*1000);
               var modified=pad(d.getDate(), 2)+'.'+pad(d.getMonth()+1,2)+'.'+d.getFullYear()+' '+pad(d.getHours(),2) + ":" + pad(d.getMinutes(), 2);
	       var button='<span class="pushbutton"><button type="button" class="form-short-small-button2" id="id-restore_'+dt+'">Restore</button></span>';
               $('#id-dialog-changelog-records-tbody').append('<tr><td>'+modified+'</td><td>'+author+(tel==undefined?"":"<br/>Tel: "+tel)+'</td><td>'+button+'</td></tr>');
           };
           $('#id-dialog-loading-message-text').hide();
	   $('button[id^=id-restore_]').unbind('click').click(function(e){
	    var the_id=this.id.split('_')[1];
	    if($('button[id=id-restore_'+the_id+']').attr("disabled") == "disabled") return false;
	    $('button[id=id-restore_'+the_id+']').attr("disabled", "disabled");
	    submit_restore(bucket_id, hex_prefix, object_key, the_id);
	    return false;
	  });
        }
    });
    stack.get_changelog(object_key);
    if($(window).width()<670){
     $("#dialog").dialog("option", "width", 300);
     $("#dialog").dialog("option", "position", { my: "center", at: "center", of: window});
    }
    $(window).resize(function(){
       if($(window).width()<670){
       $("#dialog").dialog( "option", "width", 300 );
      }else{
       $("#dialog").dialog( "option", "width", 600 );
      }
      $("#dialog").dialog( "option", "position", { my: "center", at: "center", of: window });
    });
  },
  close: function (event, ui) {
    event.stopPropagation();
    event.preventDefault();
    $("#shadow").hide();
    $(this).dialog("close");
  }
 });
 $("#dialog").dialog('open');
 return false;
}

function disable_menu_item(menu_item_id){
 if(menu_item_id=='menu-createdir'){
  $('#id-createdir-button').attr('disabled', 'disabled');
 } else if(menu_item_id=='id-upload-button'){
  $('#id-upload-button').attr('disabled', 'disabled');
 } else if(menu_item_id=='id-action-log'){
  $('#id-action-log').attr('disabled', 'disabled');
 }
}

function enable_menu_item(menu_item_id){
 if(isMobile.any() || $(window).width()<670){$("#shadow").css('z-index', 9).hide();}
 if(menu_item_id=='menu-createdir'){
  $('#id-createdir-button').removeAttr('disabled');
 } else if(menu_item_id=='menu-upload'){
  $('#id-upload-button').removeAttr('disabled');
 } else if(menu_item_id=='menu-actionlog'){
  $('#id-action-log').removeAttr('disabled');
 }

}

function validate_dirname(name, errE, callback){
 var directory_name = name.replace(/^\s+|\s+$/gm,'');
 if(directory_name.length==0){
   $(errE).append(gettext('Name can\'t be empty.'));
   if(callback) callback();
   enable_menu_item('menu-createdir');
   return false;
 }
 $(errE).empty();
 if(name.match("/\./|/\.\./|/\.$|/\.\.$")){
   $(errE).append(gettext('Name can\'t contain path.'));
   if(callback) callback();
   enable_menu_item('menu-createdir');
   return false;
 }
 if(name.length>50){
   $(errE).append('<br/>'+gettext('The length should not exceed 50 characters.'));
   if(callback) callback();
   enable_menu_item('menu-createdir');
   return false;
 }
 var fc=['"', "<", ">", "/", "\\", "|", ":", "*", "?"];
 for(var i=0;i!=fc.length;i++){
   if(name.indexOf(fc[i])!=-1){
    $(errE).append(gettext('Forbidden character: <b>'+fc[i]+'</b>.'));
    if(callback) callback();
    enable_menu_item('menu-createdir');
    return false;
   }
 }
 return true;
}

function submit_dirname(hex_prefix){
 var bucket_id = $("body").attr("data-bucket-id");
 var root_uri=$('body').attr('data-root-uri');

 $('#id-status').empty();
 $('#id_directory_name_errors').empty();
 $('#id_submit_createdir').attr("disabled", true);
 if(isMobile.any() || $(window).width()<670){$("#shadow").append('<span>Two moments please...</span>').css('z-index','1003').show();}
 disable_menu_item('menu-createdir');

 var directory_name = $('#id_directory_name').val();
 var vresult = validate_dirname(directory_name, $('#id_directory_name_errors'), function(){
   $('#id_submit_createdir').attr("disabled", false);
 });
 if(!vresult){
    return;
 }
 var stack = $.stack({'errorElementID': 'id-status',
	'rpc_url': root_uri+'list/'+bucket_id+'/',
	'onSuccess': function(data){
      $("#shadow").empty().css('z-index', 9).hide();
      enable_menu_item('menu-createdir');
      $('#id_submit_createdir').attr("disabled", false);
      fetch_file_list(bucket_id, hex_prefix, 'id-loading-message-text', 'id-objects-list', false);
      enable_menu_item('menu-createdir');
      $('.ui-dialog-titlebar-close').click();
      $('#id-status').empty();
 }, 'onFailure': function(msg, xhr, status){
      $('#id_directory_name_errors').empty();
      $('#id_directory_name_errors').append(msg);
      $('#id_submit_createdir').attr("disabled", false);
      enable_menu_item('menu-createdir');
 }});
 stack.directory_create(hex_prefix, directory_name);
}

function sort_table(column_class, order){
 var table = $('#id-objects-list');
 var asc = order === 'asc';
 table.find('.file-item').sort(function(a, b) {
  var va=$(column_class, a).text();
  var vb=$(column_class, b).text();
  if(column_class=='.file-size'){
   va=$(column_class, a).attr('data-bytes');
   vb=$(column_class, b).attr('data-bytes');
  }
  if (asc) {
    if(column_class=='.file-size'){return va > vb;}else{return va.localeCompare(vb);}
  } else {
    if(column_class=='.file-size'){return vb > va;}else{return vb.localeCompare(va);}
  }
 }).appendTo(table);
 $('.parent-dir').detach().insertBefore('#id-objects-list .file-item:first');
}

$(".cancel-btn").off('click');
$(".cancel-btn").on('click', function(){
    $('#shadow, #popup').css('display', 'none');
    return false;
});

function get_guid_version(filename){
  // TODO
  return [];
}

function upload_files(bucket_id, hex_prefix, files, dom_ids){
  var file = files.shift();
  var dom_id = dom_ids.shift();
  var root_uri=$('body').attr('data-root-uri');

  var stack = $.stack({'errorElementID': 'id-progress_'+dom_id, rpc_url: root_uri+'upload/'+bucket_id+'/', 'chunk_size': 2000000, 'onSuccess': function(data, status){
   if(data&&data.hasOwnProperty('error')){
      $('#id-progress_'+dom_id).empty().append('<span class="err">'+gettext(data['error'])+'</span>');
      return;
   };
   if(files){
    dom_id=dom_ids.shift();
    file = files.shift();
    if(file){
      stack.setErrorElementID('id-progress_'+dom_id);
      var gv = get_guid_version(file.name);
      var guid = null;
      var version = null;
      if(gv!=[]) {
	guid = gv[0];
	version = gv[1];
      }
      stack.file_upload(file, dom_id, hex_prefix, guid, version);
    } else {
      $('#id-upload-button').attr('data-uploadDisabled', false);
      if(hex_prefix){
	  fetch_file_list(bucket_id, hex_prefix, 'id-loading-message-text', 'id-objects-list', false);
	} else {
	  $('#id-action-log').attr("disabled","disabled");
	  fetch_file_list(bucket_id, NaN, 'id-loading-message-text', 'id-objects-list', false);
	}
    };
   }
  }, 'onProgress': function(evt, offset, file_size){
    if (evt.lengthComputable) {
      if(typeof(offset)=="number"&&typeof(file_size)=="number"){
	var p=parseInt(((offset+evt.loaded) / file_size * 100), 10);
      } else {
	var p=parseInt((evt.loaded / evt.total * 100), 10);
      }
      if(p>=100) {
	  p = '<span style="color:green;">100%</span>';
      } else { p = p+'%' };
      $('#id-progress_'+dom_id).empty().append(p);
    }
  }, 'onFailure': function(msg, xhr, status){
    $('#id-upload-button').attr('data-uploadDisabled', false);
    if(msg=='fd_error'){
      $('#id-progress_'+dom_id).empty().append('<span class="err">file read error</span>');
      return;
    }
    if(status=="notmodified"){
      $('#id-progress_'+dom_id).empty().append('<span class="err">'+gettext("notmodified")+'</span>');
      if(files){
        dom_id=dom_ids.shift();
        file = files.shift();
	if(file){
	  stack.setErrorElementID('id-progress_'+dom_id);
	  var gv = get_guid_version(file.name);
	  var guid = null;
	  var version = null;
	  if(gv!=[]) {
	    guid = gv[0];
	    version = gv[1];
	  }
	  stack.file_upload(file, dom_id, hex_prefix, guid, version);
	} else {
	  $('#id-upload-button').attr('data-uploadDisabled', false);
	  if(hex_prefix){
	      fetch_file_list(bucket_id, hex_prefix, 'id-loading-message-text', 'id-objects-list', false);
	  } else {
	      $('#id-action-log').attr("disabled","disabled");
	      fetch_file_list(bucket_id, NaN, 'id-loading-message-text', 'id-objects-list', false);
	  }
	};
      }
      return;
    }
    if((status=='error'||status=='timeout')&&xhr.readyState==0){
	var attempts=$('#id-progress_'+dom_id).attr('data-attempts');
	if(attempts==undefined) attempts=401; // 20 minutes with 3 seconds interval
	attempts-=1;
	$('#id-progress_'+dom_id).empty().attr('data-attempts', attempts);
	if(attempts<1){
	  $('#id-progress_'+dom_id).empty().append('<span class="err">'+gettext("connection timeout")+'</span>');
	  return;
	}
	$('#id-progress_'+dom_id).empty().append('<span class="err">'+gettext('retrying..')+'</span>');
	setTimeout(function(){
	    $('#id-progress_'+dom_id).empty().append('queueing');
            try {
	     upload_files(bucket_id, hex_prefix, [file], [dom_id]);
            } catch (e) {
            }
	}, 3000);
      return;
    } else if(msg&&status=='error'){
      $('#id-progress_'+dom_id).empty().append('<span class="err">'+gettext(msg)+'</span>');
      return;
    } else if(status=='error'){
      $('#id-progress_'+dom_id).empty().append('<span class="err">error, try later</span>');
      return;
    }
  }
 });
 var gv = get_guid_version(file.name);
 var guid = null;
 var version = null;
 if(gv!=[]) {
   guid = gv[0];
   version = gv[1];
 }
 stack.file_upload(file, dom_id, hex_prefix, guid, version);
}

function upload_dialog_add_file(file){
 var fsize_bytes = file.size;
 var fuid=fsize_bytes+file.lastModified;
 if($('#id-dialog-objects-list').find('#'+fuid).length>0) return false;
 var fsize = filesize(fsize_bytes);
 var dom_id=guid();
 $('#id-dialog-objects-list').append('<div class="file-item clearfix" id="'+dom_id+'"><div class="file-name" id="'+fuid+'"><a title="'+file.name+'" class="file-link" href="#"><i class="doc-icon"></i>'+file.name+'</a></div><div class="file-size" data-bytes="'+fsize_bytes+'">'+fsize+'</div><div><div id="id-progress_'+dom_id+'" data-attempts="5">queueing</div></div><div></div></div>');
 return dom_id;
}


$(document).on('dragenter', function(e){e.stopPropagation();e.preventDefault();});
$(document).on('dragover', function(e){e.stopPropagation();e.preventDefault();});
$(document).on('drop', function(e){e.stopPropagation();e.preventDefault();});

$(document).ready(function(){
 if (!window.File || !window.FileReader || !window.FileList || !window.Blob) {
  disable_menu_item('id-upload-button');
  $('#id-upload-button').attr('title', 'Your browser do not support HTML5');
 }

 if(isMobile.any() || $(window).width()<670){
    $('.loading-message-wrap').hide();
    $('#shadow').append('<span>Loading...</span>').show();
 }

 $(document).keydown(function(e){
    if (($("#context-menu").css('display') == 'block') && (e.which == 27 || e.keyCode == 27)){
	$("#context-menu").hide();
	$(".file-item").removeClass("current");
	if($("#shadow").css("display")=='block') $("#shadow").hide();
	$(".menu-link").hide();
    }
 });
 $(document).mousedown(function(e) {
    if (
	$("#context-menu").css('display') == 'block'
	&& e.which == 1  
	&& ($(e.target).closest('div').parent().attr('id')!='context-menu') 
	&& !($(e.target).hasClass("menu-link"))
	&& !($(e.target).parent().hasClass("menu-link"))
       )
    {
	$("#context-menu").hide();
	$(".file-item").removeClass("current");
	$(".menu-link").hide();
	if($("#shadow").css("display")=='block') $("#shadow").hide();
    }
 });

 var hex_prefix = $("body").attr("data-hex-prefix");
 var bucket_id = $("body").attr("data-bucket-id");
 if(hex_prefix){
  fetch_file_list(bucket_id, hex_prefix, 'id-loading-message-text', 'id-objects-list', false);
 } else {
  fetch_file_list(bucket_id, NaN, 'id-loading-message-text', 'id-objects-list', false);
 }

 $('.files-tbl').on('click', 'a.file-link:not(.folder)', function(){return false;})

 $('span.pushbutton').on('click', '#id-upload-button', function(){

 var u_htm = '<form id="id-dialog-upload-form" name="upload_form" enctype="multipart/form-data" method="post" > \
<div class="drop-area"> \
<span class="fileinput-button">	<span class="btn btn-green fileinput-button"><span>Add files..</span><input type="file" name="files[]" multiple="" id="id-dialog-file"></span></span> \
<span class="err" id="id_upload_errors"></span><div class="files-tbl clearfix" style="display:none;" id="id-dialog-objects-list-wrapper"><div class="files-tbl_th"> \
<div class="file-name_th"><a href="#" id="id-dialog-sort-by-name" data-sorting="asc">Name</a></div> \
<div class="file-size_th"><a href="#" id="id-dialog-sort-by-size" data-sorting="asc">Size</a></div> \
<div class="file-modified_th"><a href="#" id="id-dialog-progress">&nbsp;</a></div> \
<div></div></div><div class="clearfix" id="id-dialog-objects-list"></div></div></div></form> \
<video controls id="id-upload-video" style="display:none;"><source type="video/mp4"></video><canvas id="id-upload-canvas" style="display:none;"></canvas>';
 $("#dialog").dialog({
    title: 'Drag Files to the area below or press button to add files',
    autoOpen: false,
    resizable: false,
    height: 'auto',
    maxHeight: 600,
    width:'700',
    show: { effect: 'drop', direction: "up" },
    modal: true,
    draggable: true,
    open: function (event, ui){
        $(this).empty().append(u_htm);
    },
    close: function (event, ui){
        $("#dialog").dialog().dialog('close');
    }
 });
 $("#dialog").dialog('open');

  var da=$('.drop-area');
  da.on('dragenter', function(e){
    e.stopPropagation();e.preventDefault();$(this).css('border', '2px solid #0B85A1');
  });
  da.on('dragover', function(e){e.stopPropagation();e.preventDefault();});
  da.on('drop', function(e){
   $(this).css('border', '2px dotted #0B85A1');
   e.preventDefault();
   var d_files=new Array();
   var d_upload_ids=[];
   $.each(e.originalEvent.dataTransfer.files, function(i, file){
     d_upload_ids.push(upload_dialog_add_file(file));
     d_files.push(file);
   });
   $('#id-dialog-objects-list-wrapper').show();
   upload_files(bucket_id, hex_prefix, d_files, d_upload_ids);
  });

 $('#id-dialog-file').on('change', function(evnt){
  var files=new Array();
  var upload_ids=[];
  var hex_prefix = $("body").attr("data-hex-prefix");
  var bucket_id = $("body").attr("data-bucket-id")
  $.each(this.files, function(i, file){
    upload_ids.push(upload_dialog_add_file(file));
    files.push(file);
  });
  $('#id-dialog-objects-list-wrapper').show();

  if(files.length==0) return;
  var wait = function(){
    var is_disabled = $('#id-upload-button').attr('data-uploadDisabled');
    if(is_disabled==undefined||is_disabled=="false") {
      $('#id-upload-button').attr('data-uploadDisabled', true);
      upload_files(bucket_id, hex_prefix, files, upload_ids);
    } else {
      setTimeout(wait, 2000);
    }
  };
  wait();
 });
 return false;
});

$('span.pushbutton').on('click', '#id-action-log', function(){
 var currentElement=$(this);
 var hex_prefix=$("body").attr("data-hex-prefix");
 var bucket_id = $("body").attr("data-bucket-id");
 var root_uri = $('body').attr('data-root-uri');

 var readable_prefix=unhex(hex_prefix);
 $("#dialog").dialog({
  title: 'History for Directory "'+(readable_prefix==""?"/":readable_prefix)+'"',
  autoOpen: false,
  resizable: false,
  height: 'auto',
  width:'600',
  position: [($(window).width() / 2) - (600 / 2), 150],
  modal: true,
  draggable: false,
  open: function (event, ui) {
    $(this).empty().append('<br/><div><span id="id-dialog-loading-message-text"></span><div id="id-dialog-action-log-records"></div>');
    var stack = $.stack({
       'errorElementID': "id-dialog-loading-message-text",
       'loadingMsgColor': 'black',
       'rpc_url': root_uri+'action-log/'+bucket_id+'/',
       'onSuccess': function(data, status){
           $('#id-dialog-action-log-records').append('<div class="dry-data-container"><table class="dry-data-table" cellpadding="0" cellspacing="0"><thead><tr class="first-row"><th class="first-col" style="width:45%;">Event</th><th>&nbsp;</th><th class="last-col" style="width:20%;">User</th><th class="last-col" style="width:20%;">Date</th></tr></thead><tbody id="id-dialog-action-log-records-tbody"></tbody></table></div>');
           for(var i=0;i!=data.length;i++){
               var details=data[i].details;
               var user_name=data[i].user_name;
               var dt=data[i].timestamp;
               var d=new Date(dt*1000);
               var action_name = "";
	       var object_key=data[i].object_key;
               if(data[i].action=="delete") action_name = "Restore";
               var modified=pad(d.getDate(), 2)+'.'+pad(d.getMonth()+1,2)+'.'+d.getFullYear()+' '+pad(d.getHours(),2) + ":" + pad(d.getMinutes(), 2);
               $('#id-dialog-action-log-records-tbody').append('<tr><td>'+details+'</td><td><a id="id-action_'+i+'" href="#">'+action_name+'</a><input type="hidden" name="object_key" value="'+object_key+'"/></td><td>'+user_name+'</td><td>'+modified+'</td></tr>');
           };
           $('#id-dialog-loading-message-text').hide();
        }
    });
    stack.get_action_log(hex_prefix);
    if($(window).width()<670){
     $("#dialog").dialog("option", "width", 300);
     $("#dialog").dialog("option", "position", { my: "center", at: "center", of: window});
    }
    $(window).resize(function(){
       if($(window).width()<670){
       $("#dialog").dialog( "option", "width", 300 );
      }else{
       $("#dialog").dialog( "option", "width", 600 );
      }
      $("#dialog").dialog( "option", "position", { my: "center", at: "center", of: window });
    });
  },
  close: function (event, ui) {
    event.stopPropagation();
    event.preventDefault();
    $("#shadow").hide();
    $(this).dialog("close");
  }
 });
 $("#dialog").dialog('open');
 return false;
});

$('span.pushbutton').on('click', '#id-createdir-button', function(){
 var currentElement=$(this);
 var hex_prefix=$("body").attr("data-hex-prefix");
 var d_htm = '<form action="" id="id_createdir_form" name="createdir_form" > \
<br/><input name="directory_name" id="id_directory_name"/> \
<span class="pushbutton"><button type="button" class="form-short-small-button2" id="id_submit_createdir">Submit</button></span> \
<span class="err" id="id_directory_name_errors"></span></form>';
 $("#dialog").dialog({
        title: 'New Directory Name',
        autoOpen: false,
        resizable: false,
        height: 'auto',
	width:'40%',
        show: { effect: 'drop', direction: "up" },
        modal: true,
        draggable: true,
	create: function( event, ui ) {
	    // Set maxWidth
	    $(this).closest('.ui-dialog').css("maxWidth", "400px");
	},
        open: function (event, ui) {
            $(this).empty().append(d_htm);
        },
        close: function (event, ui) {
            $("#dialog").dialog().dialog('close');
	    $("#shadow").empty().hide();
        }
 });
 $("#dialog").dialog('open');
 $('#id_directory_name').unbind('keydown').keydown(function(e){
    var key;
    if(window.event) key = window.event.keyCode;
    else key = e.which;
    if(key == 13) return false;
 });
 $('#id_directory_name').unbind('keyup').keyup(function(e){
    var key;
    if(window.event) key = window.event.keyCode;
    else key = e.which;
    if(key == 13) {
      submit_dirname(hex_prefix);
      return false;
    }
 });
 $('#id_createdir_form').submit(function(e){
  submit_dirname(hex_prefix);
 });
 $('#id_directory_name').focus();
 $('#id_submit_createdir').unbind('click').click(function(){
  submit_dirname(hex_prefix);
  return false;
 });
 return false;
});

$('.files-tbl').on('click', 'a#id-sort-by-name', function(){
 var order=($(this).attr('data-sorting')=='asc')?'dsc':'asc';
 sort_table('.file-name', order);
 $(this).attr('data-sorting', order);
 return false;
});

$('.files-tbl').on('click', 'a#id-sort-by-date', function(){
 var order=($(this).attr('data-sorting')=='asc')?'dsc':'asc';
 sort_table('.file-modified', order);
 $(this).attr('data-sorting', order);
 return false;
});

$('.files-tbl').on('click', 'a#id-sort-by-size', function(){
 var order=($(this).attr('data-sorting')=='asc')?'dsc':'asc';
 sort_table('.file-size', order);
 $(this).attr('data-sorting', order);
 return false;
});

$('#obj_search').autocomplete({
  source: function(req, responseFn) {
    $.ajax({
     url: "/internal_solr/binary_objects/suggest",
     cache: false,
     dataType: 'json',
     data: {
      q: req.term,
      wt: "json"
     },
     success: function(data, status) {
	var result = [];
	$(data['grouped']['orig_name']['groups']).each(function(i,v){
	  result.push(v.groupValue)
	});
        responseFn( result );
     }
    });
  },
  minLength: 1
});

var search_form = $('#search_form').ajaxForm({
   success: function(data){
     $('#search_form input[type=button]').removeAttr("disabled");
     if(isMobile.any() || $(window).width()<670){
	$('#shadow').empty().hide();
     }else{
	$('.loading-message-wrap').hide();
     }
     var lst = $('#id-objects-list');
     var directories=[];
     var embedded=false;
     var stack = $.stack();
     $(lst).empty();
     if(!embedded) {
      display_objects(lst, $('#id-block-header'), NaN, data, stack, embedded);
      enable_menu_item('menu-createdir');
      disable_menu_item('id-menu-action-log');
      refreshMenu();
     } else {
      display_objects(lst, $('#id-dialog-block-header'), NaN, data, stack, embedded);
     }
     $('.files-tbl').show();
     if($(window).width()<670) {
	$(".file-link").width($('.file-item').width());
     }
     return false;
   }
});

$('#search_form input[type=button]').click(function(){
 $('#search_form input[type=button]').attr("disabled","");
 search_form.submit();
 return false;
});

});
