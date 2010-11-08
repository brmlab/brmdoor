<?php

function post_irc($open) {

  $server = 'irc.freenode.net';
  $port   = 6667;
  $nick   = 'brmdoor';
  $ident  = 'brmdoor';
  $host   = 'brmlab.cz';
  $chan   = '#brmlab';
  $name   = 'Brmlab Gatekeeper';

  $fp = fsockopen($server, $port, $errno, $errstr, 30);

  if (!$fp) return;

  fwrite($fp, "USER $ident $host $nick :$name\r\n");
  fwrite($fp, "NICK $nick\r\n");
  fwrite($fp, "JOIN $chan\r\n");

  $topic = '';
  while (!feof($fp)) {
    $line = fgets($fp,256);
    $data = explode(' ', $line, 5);
    if ($data[1] == '366') break;
    if ($data[1] == '332') {
      $topic = $data[4];
     break;
    }
  }

  if (!$topic) {
    $topic = $open ? 'BRMLAB OPEN' : 'BRMLAB CLOSED';
  } else {
    $topic = explode('|', $topic, 2);
    @ $topic = ($open ? 'BRMLAB OPEN' : 'BRMLAB CLOSED') . ' | ' . trim($topic[1]);
  }

  fwrite($fp, "TOPIC $chan :$topic\r\n");
  while (!feof($fp)) {
    $line = fgets($fp,256);
    $data = explode(' ', $line, 3);
    if ($data[1] == 'TOPIC') break;
  }

  fclose($fp);
}



function get_state() {
  $h = fopen('brmdoor.txt', 'r');
  $contents = fread($h, 128);
  $r = $contents[0] == '1';
  fclose($h);
  return $r;
}

function set_state($open) {
  $h = fopen('brmdoor.txt', 'w');
  fwrite($h, $open ? '1' : '0');
  fclose($h);
}

if ($_POST['state']) {
  if ($_POST['state'] == 'OPEN') {
    set_state(true);
    post_irc(true);
  }
  if ($_POST['state'] == 'CLOSE') {
    set_state(false);
    post_irc(false);
  }
}

$state = get_state();

?>
<!DOCTYPE HTML>
<html>
<head>
<title>Brmdoor</title>
</head>
<body>
<h1><i>brmlab is</i> <?php echo $state ? 'open' : 'closed'; ?></h1>
<form action="" method="post">
<input type="submit" name="state" value="OPEN"<?php if ($state) echo " disabled"; ?>>
<input type="submit" name="state" value="CLOSE"<?php if (!$state) echo " disabled"; ?>>
</form>
</body>
</html>
