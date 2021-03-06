(:
  Copyright 2012-2016 MarkLogic Corporation

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
:)
xquery version "1.0-ml";

module namespace flow = "http://marklogic.com/data-hub/flow-lib";

import module namespace config = "http://marklogic.com/data-hub/config"
  at "/com.marklogic.hub/lib/config.xqy";

import module namespace debug = "http://marklogic.com/data-hub/debug"
  at "/com.marklogic.hub/lib/debug-lib.xqy";

import module namespace hul = "http://marklogic.com/data-hub/hub-utils-lib"
  at "/com.marklogic.hub/lib/hub-utils-lib.xqy";

import module namespace json="http://marklogic.com/xdmp/json"
  at "/MarkLogic/json/json.xqy";

import module namespace functx = "http://www.functx.com"
  at "/MarkLogic/functx/functx-1.0-nodoc-2007-01.xqy";

import module namespace trace = "http://marklogic.com/data-hub/trace"
  at "/com.marklogic.hub/lib/trace-lib.xqy";

declare namespace hub = "http://marklogic.com/data-hub";

declare namespace envelope = "http://marklogic.com/data-hub/envelope";

declare option xdmp:mapping "false";

(: xml describing the default writer :)
declare variable $DEFAULT-WRITER :=
  element hub:writer {
    attribute type { "xquery" },
    attribute module { "/com.marklogic.hub/writers/default.xqy" }
  };

(: xml describing the default content plugin :)
declare variable $DEFAULT-CONTENT-PLUGIN :=
  element hub:plugin {
    attribute dest { "content" },
    attribute type { "xquery" },
    attribute module { "/com.marklogic.hub/plugins/raw.xqy" }
  };

(: xml describing a no-op plugin. used when no plugin is given :)
declare variable $NO-OP-PLUGIN :=
  element hub:plugin {
    attribute type { "null" }
  };

(: the directory where entities live :)
declare variable $ENTITIES-DIR := "/entities/";

declare variable $PLUGIN-NS := "http://marklogic.com/data-hub/plugins";

declare variable $TYPE-XQUERY := "xquery";

declare variable $TYPE-JAVASCRIPT := "javascript";

declare variable $TYPE-XSLT := "xslt";
declare variable $TYPE-XML := "xml";
declare variable $TYPE-JSON := "json";
declare variable $XML := "application/xml";
declare variable $JSON := "application/json";

declare function flow:get-module-ns(
  $type as xs:string) as xs:string?
{
  if ($type eq $TYPE-JAVASCRIPT) then ()
  else
    $PLUGIN-NS
};

(:
 : Determines the type of flow given a filename
 :
 : @param $filename - name of the module plugin file
 : @return - a type (xquery, xml, sjs, ...)
 :)
declare %private function flow:get-type($filename) as xs:string?
{
  let $ext as xs:string := hul:get-file-extension($filename)
  return
    if ($ext = hul:get-xqy-extensions()) then
      $TYPE-XQUERY
    else if ($ext = hul:get-sjs-extensions()) then
      $TYPE-JAVASCRIPT
    else if ($ext = hul:get-xslt-extensions()) then
      $TYPE-XSLT
    else if ($ext = "xml") then
      $TYPE-XML
    else if ($ext = "json") then
      $TYPE-JSON
    else
      fn:error(xs:QName("INVALID_PLUGIN"), $filename)
};

(:~
 : Returns xml describing a collector
 :)
declare %private function flow:get-collector(
  $flow-name as xs:string,
  $uris as xs:string*) as element(hub:collector)
{
  let $uri := $uris[1]
  let $filename as xs:string := hul:get-file-from-uri($uri)
  let $type := flow:get-type($filename)
  return
    element hub:collector {
      attribute type { $type },
      attribute module { $uri }
    }
};

(:~
 : Returns xml describing a plugin
 :)
declare %private function flow:get-plugin(
  $flow-name as xs:string,
  $uris as xs:string*,
  $destination as xs:string) as element(hub:plugin)*
{
  for $uri in $uris
  let $filename as xs:string := hul:get-file-from-uri($uri)
  let $type := flow:get-type($filename)
  return
    element hub:plugin {
      attribute dest { $destination },
      attribute type { $type },
      attribute module { $uri }
    }
};

(:~
 : Returns xml describing a content plugin
 :)
declare %private function flow:get-content(
  $flow-name as xs:string,
  $uris as xs:string*)
{
  let $plugin := flow:get-plugin($flow-name, $uris, "content")
  return
    if ($plugin) then $plugin
    else
      $DEFAULT-CONTENT-PLUGIN
};

(:~
 : Returns xml describing a headers plugin
 :)
declare %private function flow:get-headers(
  $flow-name as xs:string,
  $uris as xs:string*)
{
  let $plugin := flow:get-plugin($flow-name, $uris, "headers")
  return
    if ($plugin) then $plugin
    else
      $NO-OP-PLUGIN
};

(:~
 : Returns xml describing a triples plugin
 :)
declare %private function flow:get-triples(
  $flow-name as xs:string,
  $uris as xs:string*)
{
  let $plugin := flow:get-plugin($flow-name, $uris, "triples")
  return
    if ($plugin) then $plugin
    else
      $NO-OP-PLUGIN
};

(:~
 : Returns xml describing a writer
 :)
declare %private function flow:get-writer(
  $flow-name as xs:string,
  $uris as xs:string*)
{
  if ($uris) then
    for $uri in $uris
    let $filename as xs:string := hul:get-file-from-uri($uri)
    let $type := flow:get-type($filename)
    return
      element hub:writer {
        attribute type { $type },
        attribute module { $uri }
      }
  else
    $DEFAULT-WRITER
};

(:~
 : Returns a flow by name. This xml is dynamically constructed
 : by looking in the modules database.
 :
 : @param $entity-name - name of the entity that owns the flow
 : @param $flow-name - name of the flow to retrieve
 : @return - xml describing the flow
 :)
declare function flow:get-flow(
  $entity-name as xs:string,
  $flow-name as xs:string,
  $flow-type as xs:string?) as element(hub:flow)?
{
  let $cache-name := fn:string-join(("flow:", $entity-name, $flow-name, $flow-type), "-")
  return
    hul:from-field-cache($cache-name, function() {
      let $uris :=
        hul:run-in-modules(function() {
          let $type :=
            if ($flow-type) then $flow-type
            else "*"
          return
            cts:uri-match($ENTITIES-DIR || $entity-name || "/" || $type || "/" || $flow-name || "/*")
        })
      where fn:count($uris) > 0
      return
        flow:get-flow($entity-name, $flow-name, $flow-type, $uris)
    },
    xs:dayTimeDuration("PT10M"))
};

declare function flow:invalidate-flow-caches()
{
  for $name in xdmp:get-server-field-names()
  where fn:starts-with($name, "flow:")
  return
    xdmp:set-server-field($name, ())
};

(:~
 : Returns a flow by name. This xml is dynamically constructed
 : by looking in the modules database.
 :
 : @param $entity-name - name of the entity that owns the flow
 : @param $flow-name - name of the flow to retrieve
 : @param $uris - uris used to build the entity xml
 : @return - xml describing the flow
 :)
declare %private function flow:get-flow(
  $entity-name as xs:string,
  $flow-name as xs:string,
  $flow-type as xs:string?,
  $uris as xs:string*) as element(hub:flow)
{
  let $real-flow-type := fn:replace($uris[1], $ENTITIES-DIR || $entity-name || "/([^/]+)/" || $flow-name || ".*$", "$1")
  let $map := map:map()
  let $_ :=
    let $type :=
      if ($flow-type) then $flow-type
      else "[^/]+"
    let $regex := $ENTITIES-DIR || $entity-name || "/" || $type || "/" || $flow-name || "/([^/]+)/.*$"
    for $dir in $uris
    let $dir-name := fn:replace($dir, $regex, "$1")
    let $child-uris := $uris[fn:matches(., $ENTITIES-DIR || $entity-name || "/" || $type || "/" || $flow-name || "/" || $dir-name || "/([^/]+)$")]
    return
      switch ($dir-name)
        case "collector" return
          map:put($map, "collector", flow:get-collector($flow-name, $child-uris))
        case "content" return
          map:put($map, "content", flow:get-content($flow-name, $child-uris))
        case "headers" return
          map:put($map, "headers", flow:get-headers($flow-name, $child-uris))
        case "triples" return
          map:put($map, "triples", flow:get-triples($flow-name, $child-uris))
        case "writer" return
          map:put($map, "writer", flow:get-writer($flow-name, $child-uris))
        default return
          ()
  let $flow := hul:run-in-modules(function() {
    let $uri := $ENTITIES-DIR || $entity-name || "/" || $real-flow-type || "/" || $flow-name || "/" || $flow-name || ".xml"
    return
      fn:doc($uri)/hub:flow
  })
  return
    <flow xmlns="http://marklogic.com/data-hub">
      <name>{$flow-name}</name>
      <entity>{$entity-name}</entity>
      <complexity>{ ($flow/hub:complexity/fn:data(), "simple")[1] }</complexity>
      <data-format>{ $flow/hub:data-format/fn:data() }</data-format>
      <type>{$real-flow-type}</type>
      {map:get($map, "collector")}
      <plugins>
      {
        if ($flow/hub:plugins/*) then
          $flow/hub:plugins/*
        else
        (
          (map:get($map, "content"), $DEFAULT-CONTENT-PLUGIN)[1],
          (map:get($map, "headers"), $NO-OP-PLUGIN)[1],
          (map:get($map, "triples"), $NO-OP-PLUGIN)[1]
        )
      }
      </plugins>
      {
        (map:get($map, "writer"), $DEFAULT-WRITER)[1]
      }
    </flow>
};

(:~
 : Returns the flows that belong to the given entity in the database
 :
 : @param $entity-name - the name of the entity containing the flows
 : @return - xml describing the flows
 :)
declare function flow:get-flows(
  $entity-name as xs:string) as element(hub:flows)
{
  let $uris := hul:run-in-modules(function() {
    cts:uri-match($ENTITIES-DIR || "*")
  })
  let $flow-names :=
    fn:distinct-values(
      let $regex := $ENTITIES-DIR || $entity-name || "/(input|harmonize)/([^/]+)/.*$"
      for $flow in $uris[fn:matches(., $regex)]
      let $name := fn:replace($flow, $regex, "$2")
      return
        $name)
  let $flows :=
    for $flow-name in $flow-names
    return
      flow:get-flow($entity-name, $flow-name, (), $uris[fn:matches(., $ENTITIES-DIR || $entity-name || "/(input|harmonize)/" || $flow-name || "/.+")])
  return
    <flows xmlns="http://marklogic.com/data-hub">
    {
      $flows
    }
    </flows>
};

(:~
 : Returns a entity by name. This xml is dynamically constructed
 : by looking in the modules database.
 :
 : @param $entity-name - name of the entity to retrieve
 : @return - xml describing the entity
 :)
declare function flow:get-entity(
  $entity-name as xs:string)
{
  let $uris :=
    hul:run-in-modules(function() {
      cts:uri-match($ENTITIES-DIR || $entity-name || "/*")
    })
  return
    flow:get-entity($entity-name, $uris)
};

(:~
 : Returns a entity by name. This xml is dynamically constructed
 : by looking in the modules database.
 :
 : @param $entity-name - name of the entity to retrieve
 : @param $uris - uris used to build the entity xml
 : @return - xml describing the entity
 :)
declare %private function flow:get-entity(
  $entity-name as xs:string,
  $uris as xs:string*)
  as element(hub:entity)
{
  <entity xmlns="http://marklogic.com/data-hub">
    <name>{$entity-name}</name>
    {
      flow:get-flows($entity-name)
    }
  </entity>
};

(:~
 : Returns the entities in the database
 :
 : @return - xml describing the entities
 :)
declare function flow:get-entities() as element(hub:entities)
{
  let $uris := hul:run-in-modules(function() {
    cts:uri-match($ENTITIES-DIR || "*")
  })
  let $entity-names :=
    fn:distinct-values(
      let $regex := $ENTITIES-DIR || "([^/]+)/.*$"
      for $flow in $uris[fn:matches(., $regex)]
      let $name := fn:replace($flow, $regex, "$1")
      return
        $name)
  let $entities :=
    for $entity-name in $entity-names
    return
      flow:get-entity($entity-name, $uris[fn:matches(., $ENTITIES-DIR || $entity-name || "/.+")])
  return
    <entities xmlns="http://marklogic.com/data-hub">
    {
      $entities
    }
    </entities>
};

(:~
 : Runs a collector
 :
 : @param $module-uri - the uri of the collector module
 : @param $options - a map of options passed in by the client
 : @return - a sequence of strings
 :)
declare function flow:run-collector(
  $job-id as xs:string,
  $module-uri as xs:string,
  $options as map:map) as item()*
{
  let $_ := trace:set-job-id($job-id)
  let $filename as xs:string := hul:get-file-from-uri($module-uri)
  let $type := flow:get-type($filename)
  let $ns := flow:get-module-ns($type)
  let $func := xdmp:function(fn:QName($ns, "collect"), $module-uri)
  let $_ := trace:init-trace("json")
  let $before := xdmp:elapsed-time()
  let $resp :=
    try {
      $func($options)
    }
    catch($ex) {
      debug:log(xdmp:describe($ex, (), ())),
      trace:error-trace(
        (),
        $module-uri,
        "collector",
        "harmonize",
        (),
        $ex,
        xdmp:elapsed-time() - $before
      ),
      xdmp:rethrow()
    }
  let $_ :=
    trace:plugin-trace(
      null-node {},
      $module-uri,
      "collector",
      "harmonize",
      null-node {},
      if ($resp instance of json:array) then $resp
      else json:to-array($resp),
      xdmp:elapsed-time() - $before
    )
  let $_ := trace:write-trace()
  return
    $resp
};

(:~
 : Runs a given flow
 :
 : @param $flow - xml describing the flow
 : @param $identifier - the identifier to send to the flow steps (URI in corb lingo)
 : @param $options - a map of options passed in by the client
 : @return - nothing
 :)
declare function flow:run-flow(
  $job-id as xs:string,
  $flow as element(hub:flow),
  $identifier as xs:string,
  $target-database as xs:unsignedLong,
  $options as map:map) as empty-sequence()
{
  map:set-javascript-by-ref($options, fn:true()),
  flow:run-flow($job-id, $flow, $identifier, (), $target-database, $options)
};

declare function flow:run-plugins(
  $flow as element(hub:flow),
  $identifier as xs:string,
  $content as item()?,
  $options as map:map
)
{
  let $content :=
    map:new((
      map:entry("identifier", $identifier),
      if ($content) then
        map:entry("content", $content)
      else ()
    ))
  let $data-format := $flow/hub:data-format
  let $flow-type := $flow/hub:type
  let $flow-complexity := $flow/hub:complexity
  let $_ := trace:init-trace(
    if ($data-format = $XML) then "xml"
    else "json")
  let $_ :=
    for $plugin in $flow/hub:plugins/hub:plugin
    let $destination := $plugin/@dest
    let $resp :=
      flow:run-plugin(
        $plugin,
        $data-format,
        $identifier,
        map:get($content, "content"),
        map:get($content, "headers"),
        map:get($content, "triple"),
        $flow-type,
        $flow-complexity = "simple",
        $options)
    return
      if (fn:empty($destination))
      then ()
      else map:put($content, $destination, $resp)
  return
    flow:make-envelope($content, $data-format)
};

declare function flow:run-flow(
  $job-id as xs:string,
  $flow as element(hub:flow),
  $identifier as xs:string,
  $content as item()?,
  $target-database as xs:unsignedLong,
  $options as map:map) as empty-sequence()
{
  (: assert that we are in query mode :)
  let $_ts as xs:unsignedLong := xdmp:request-timestamp()
  let $_ := trace:set-job-id($job-id)
  let $envelope := flow:run-plugins($flow, $identifier, $content, $options)
  let $_ :=
    for $writer in $flow/hub:writer
    return
      flow:run-writer(
        $writer, $identifier, $envelope,
        $flow/hub:type, $flow/hub:data-format,
        $target-database, $options)
  let $_ := trace:write-trace()
  return
    ()
};

(:~
 : Construct an envelope
 :
 : @param $map - a map with all the stuff in it
 : @return - the newly constructed envelope
 :)
declare function flow:make-envelope(
  $map as map:map,
  $data-format as xs:string)
{
  if ($data-format eq $JSON) then
    let $headers := fn:head((map:get($map, "headers"), json:array()))
    let $triples := fn:head((map:get($map, "triples"), json:array()))
    let $content := fn:head((map:get($map, "content"), json:object()))
    return
      xdmp:to-json(map:new((
        map:entry("headers", $headers),
        map:entry("triples", $triples),
        map:entry("content", $content)
      )))/node()
  else
    <envelope xmlns="http://marklogic.com/data-hub/envelope">
      <headers>{map:get($map, "headers")}</headers>
      <triples>{map:get($map, "triples")}</triples>
      <content>{map:get($map, "content")}</content>
    </envelope>
};

(: Formats the input for a trace based on the plugin type :)
declare function flow:get-trace-input(
  $plugin as element(hub:plugin),
  $data-format as xs:string,
  $content as item()?,
  $headers as item()*,
  $flow-type as xs:string)
{
  let $destination as xs:string := $plugin/@dest
  let $content :=
    if ($content instance of document-node()) then
      $content/node()
    else
      $content
  let $o := json:object()
  let $_ :=
    switch($destination)
      case "content" return
        if ($flow-type = "input") then
          if ($content instance of binary()) then
            map:put($o, "rawContent", "binary document")
          else
            map:put($o, "rawContent", $content)
        else
          ()
      case "headers" return
        map:put($o, "content", $content)
      case "triples" return
      (
        map:put($o, "content", $content),
        map:put($o, "headers", ($headers, null-node{})[1])
      )
      default return ()
  return
    if ($data-format = $XML) then
      for $key in map:keys($o)
      return
        element { $key } {
          let $value := map:get($o, $key)
          return
            if ($value instance of null-node()) then ()
            else $value
        }
    else
      $o
};

(: Calls a plugin's function with the appropriate parameters :)
declare function flow:call-plugin-function(
  $plugin as element(hub:plugin),
  $identifier as xs:string,
  $content as item()?,
  $headers as item()*,
  $triples as sem:triple*,
  $flow-type as xs:string,
  $simple as xs:boolean,
  $options as map:map)
{
  let $destination as xs:string := $plugin/@dest
  let $func := flow:get-function($plugin)
  let $resp :=
    if ($simple) then
      switch ($destination)
        case "content" return
          if ($flow-type = "input") then
            $func($identifier, $content, $options)
          else
            $func($identifier, $options)
        case "headers" return
          $func($identifier, $content, $options)
        case "triples" return
          $func($identifier, $content, $headers, $options)
        default return ()
    else
      $func($identifier, $content, $headers, $triples, $options)
  return
    if ($resp instance of binary()) then
      fn:error(xs:QName("CANT_RETURN_BINARY"), "You can't put a binary inside of an envelope.")
    else
      $resp
};

(:~
 : Run a given plugin
 :
 : @param $plugin - xml describing the plugin to run
 : @param $identifier - the identifier to send to the flow steps (URI in corb lingo)
 : @param $content - the output of the content plugin
 : @param $headers - the output of the headers plugin
 : @param $triples - the output of the triples plugin
 : @param $options - a map of options passed in by the client
 : @return - the output of the plugin. It varies.
 :)
declare function flow:run-plugin(
  $plugin as element(hub:plugin),
  $data-format as xs:string,
  $identifier as xs:string,
  $content as item()?,
  $headers as item()*,
  $triples as sem:triple*,
  $flow-type as xs:string,
  $simple as xs:boolean,
  $options as map:map)
{
  (: blow up if there is no module uri :)
  if (fn:empty($plugin/@module)) then
    fn:error(xs:QName("MISSING-MODULE-URI"), "The given plugin xml is missing a @module uri")
  else (),

  let $module-uri as xs:string? := $plugin/@module
  let $destination as xs:string := $plugin/@dest
  let $trace-input := flow:get-trace-input($plugin, $data-format, $content, $headers, $flow-type)
  let $before := xdmp:elapsed-time()
  let $resp :=
    try {
      flow:call-plugin-function(
        $plugin, $identifier, $content,
        $headers, $triples, $flow-type,
        $simple, $options)
    }
    catch($ex) {
      debug:log(xdmp:describe($ex, (), ())),
      trace:error-trace(
        $identifier,
        $module-uri,
        $destination,
        $flow-type,
        $trace-input,
        $ex,
        xdmp:elapsed-time() - $before
      ),
      xdmp:rethrow()
    }
  let $duration := xdmp:elapsed-time() - $before
  let $resp :=
    typeswitch($resp)
      case document-node() return
        if (fn:count($resp/node()) > 1) then
          fn:error(xs:QName("TOO_MANY_NODES"), "Too Many Nodes!. Return just 1 node")
        else
          $resp/node()
      default return
        $resp

  (: clean up output :)
  let $resp :=
    typeswitch($resp)
      case object-node() | json:object return
        (: object with $type key is ES response type :)
        if ($resp instance of map:map and map:keys($resp) = "$type") then
          $resp
        else if ($data-format = $XML) then
          json:transform-from-json($resp, json:config("custom"))
        else
          $resp
      case json:array return
        if ($data-format = $XML) then
          json:array-values($resp)
        else
          $resp
      default return
        if ($data-format = $JSON and
            flow:get-type(hul:get-file-from-uri($module-uri)) = $TYPE-XQUERY and
            $destination = "triples") then
          json:to-array($resp)
        else
          $resp

  (: log the trace event :)
  let $_ :=
    trace:plugin-trace(
      $identifier,
      $module-uri,
      $destination,
      $flow-type,
      $trace-input,
      if ($data-format = $XML) then
        $resp
      else
        ($resp, null-node{})[1],
      $duration
    )
  return
    $resp
};

(:~
 : Run a given writer
 :
 : @param $writer - xml describing the writer to run
 : @param $identifier - the identifier to send to the flow steps (URI in corb lingo)
 : @param $envelope - the envelope
 : @param $options - a map of options passed in by the client
 : @return - the output of the writer. It varies.
 :)
declare function flow:run-writer(
  $writer as element(hub:writer),
  $identifier as xs:string,
  $envelope as item(),
  $flow-type as xs:string,
  $data-format as xs:string,
  $target-database as xs:unsignedLong,
  $options as map:map)
{
  let $module-uri as xs:string := $writer/@module
  let $filename as xs:string := hul:get-file-from-uri($module-uri)
  let $type := flow:get-type($filename)
  let $ns := flow:get-module-ns($type)
  let $func := xdmp:function(fn:QName($ns, "write"), $module-uri)
  let $before := xdmp:elapsed-time()
  let $resp :=
    try {
      xdmp:eval('
        declare variable $func external;
        declare variable $identifier external;
        declare variable $envelope external;
        declare variable $options external;

        $func($identifier, $envelope, $options)
      ',
      map:new((
        map:entry("func", $func),
        map:entry("identifier", $identifier),
        map:entry("envelope", $envelope),
        map:entry("options", $options)
      )),
      map:new((
        map:entry("isolation", "different-transaction"),
        map:entry("database", $target-database),
        map:entry("transactionMode", "update-auto-commit")
      )))
    }
    catch($ex) {
      debug:log(xdmp:describe($ex, (), ())),
      trace:error-trace(
        $identifier,
        $module-uri,
        "writer",
        $flow-type,
        $envelope,
        $ex,
        xdmp:elapsed-time() - $before
      ),
      xdmp:rethrow()
    }
  let $duration := xdmp:elapsed-time() - $before
  let $_ :=
    trace:plugin-trace(
      $identifier,
      $module-uri,
      "writer",
      $flow-type,
      $envelope,
      if ($data-format eq $flow:XML) then ()
      else null-node {},
      $duration
    )
  return
    $resp
};

declare function flow:make-error-json(
  $errors as json:object,
  $entity as xs:string,
  $flow  as xs:string,
  $plugin as xs:string,
  $ex
) {
  let $eo :=
    if (map:contains($errors, $entity)) then
      map:get($errors, $entity)
    else
      let $e := map:map()
      let $_ := map:put($errors, $entity, $e)
      return
        $e
  let $fo :=
    if (map:contains($eo, $flow)) then
      map:get($eo, $flow)
    else
      let $f := map:map()
      let $_ := map:put($eo, $flow, $f)
      return
        $f

  let $f := $ex/error:stack/error:frame[1]
  return
    map:put($fo, $plugin, map:new((
      map:entry("uri", $f/error:uri/fn:data()),
      map:entry("line", $f/error:line/fn:data()),
      map:entry("column", $f/error:column/fn:data()),
      map:entry("msg", $ex/error:format-string/fn:data())
    )))
};

declare function flow:validate-entities()
{
  let $errors := json:object()
  let $options := map:map()
  let $_ :=
    for $entity in flow:get-entities()/hub:entity
    for $flow in $entity/hub:flows/hub:flow
    let $data-format := $flow/hub:data-format
    (: validate collector :)
    let $_ :=
      try {
        let $collector := $flow/hub:collector
        return
          if ($collector) then
            let $module-uri := $collector/@module
            let $filename as xs:string := hul:get-file-from-uri($module-uri)
            let $type := flow:get-type($filename)
            let $ns := flow:get-module-ns($type)
            return
              if ($type eq $flow:TYPE-XQUERY) then
                xdmp:eval(
                  'import module namespace x = "' || $ns || '" at "' || $module-uri || '"; ' ||
                  '()',
                  map:new(map:entry("staticCheck", fn:true()))
                )
              else
                xdmp:javascript-eval(
                  'var x = require("' || $module-uri || '");',
                  map:new(map:entry("staticCheck", fn:true()))
                )
          else ()
      }
      catch($ex) {
        flow:make-error-json(
          $errors,
          $entity/hub:name,
          $flow/hub:name,
          "collector",
          $ex)
      }
    (: validate plugins :)
    let $_ :=
      for $plugin in $flow/hub:plugins/hub:plugin[fn:exists(@module)]
      let $destination := $plugin/@dest
      let $module-uri := $plugin/@module
      let $filename as xs:string := hul:get-file-from-uri($module-uri)
      let $type := flow:get-type($filename)
      let $ns := flow:get-module-ns($type)
      return
        (:
         : Note that we are static checking the files.
         : This is because there is no reasonable way to actually
         : call the plugins and pass in data that will work for all plugins.
         :
         : The disadvantage to static checking is that we will not catch typos
         : like ctsdoc <- (missing period) because Javascript is dynamically
         : typed. Static checking will only catch syntax errors in sjs.
         :)
        try {
          if ($type eq $flow:TYPE-XQUERY) then
            xdmp:eval(
              'import module namespace x = "' || $ns || '" at "' || $module-uri || '"; ' ||
              '()',
              map:new(map:entry("staticCheck", fn:true()))
            )
          else
            xdmp:javascript-eval(
              'var x = require("' || $module-uri || '");',
              map:new(map:entry("staticCheck", fn:true()))
            )
        }
        catch($ex) {
          flow:make-error-json(
            $errors,
            $entity/hub:name,
            $flow/hub:name,
            $destination,
            $ex)
        }
    return
      ()
  return
    map:new(
      map:entry("errors", $errors)
    )
};

(: Returns the plugin function to be called :)
declare %private function flow:get-function($plugin as element(hub:plugin))
  as xdmp:function
{
  let $module-uri as xs:string := $plugin/@module
  let $destination as xs:string := $plugin/@dest
  let $filename as xs:string := hul:get-file-from-uri($module-uri)
  let $type := flow:get-type($filename)
  let $ns := flow:get-module-ns($type)
  let $func-name :=
    if ($type eq $TYPE-JAVASCRIPT) then
      "create" || functx:capitalize-first($destination)
    else
      "create-" || $destination
  return
    xdmp:function(fn:QName($ns, $func-name), $module-uri)
};


