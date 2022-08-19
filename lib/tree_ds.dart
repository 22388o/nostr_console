import 'dart:io';
import 'package:nostr_console/event_ds.dart';

class Tree {
  Event             e;
  List<Tree>        children;
  Map<String, Tree> allChildEventsMap;
  List<String>      eventsWithoutParent;
  Tree(this.e, this.children, this.allChildEventsMap, this.eventsWithoutParent);

  // @method create top level Tree from events. 
  // first create a map. then process each element in the map by adding it to its parent ( if its a child tree)
  factory Tree.fromEvents(List<Event> events) {
    if( events.isEmpty) {
      return Tree(Event("","",EventData("non","", 0, 0, "", [], [], [], [[]], {}), [""], "[json]"), [], {}, []);
    }

    // create a map from list of events, key is eventId and value is event itself
    Map<String, Tree> allChildEventsMap = {};
    events.forEach((event) { allChildEventsMap[event.eventData.id] = Tree(event, [], {}, []); });

    // this will become the children of the main top node. These are events without parents, which are printed at top.
    List<Tree>  topLevelTrees = [];

    List<String> tempWithoutParent = [];
    allChildEventsMap.forEach((key, value) {

      if( value.e.eventData.kind != 1) {
        return;
      }

      if(value.e.eventData.eTagsRest.isNotEmpty ) {
        // is not a parent, find its parent and then add this element to that parent Tree
        //stdout.write("added to parent a child\n");
        String id = key;
        String parentId = value.e.eventData.getParent();
        if( allChildEventsMap[parentId]?.e.eventData.kind != 1) { // since parent can only be a kind 1 event
          return;
        }

        if(allChildEventsMap.containsKey( parentId)) {
           allChildEventsMap[parentId]?.addChildNode(value); // in this if condition this will get called
        } else {
           // in case where the parent of the new event is not in the pool of all events, 
           // then we create a dummy event and put it at top ( or make this a top event?) TODO handle so that this can be replied to, and is fetched
           Tree dummyTopNode = Tree(Event("","",EventData("Unk" ,gDummyAccountPubkey, value.e.eventData.createdAt , 0, "Unknown parent event", [], [], [], [[]], {}), [""], "[json]"), [], {}, []);
           dummyTopNode.addChildNode(value);
           tempWithoutParent.add(value.e.eventData.id); 
          
           // add the dummy evnets to top level trees, so that their real children get printed too with them
           // so no post is missed by reader
           topLevelTrees.add(dummyTopNode);
        }
      }
    });

    // add parent trees as top level child trees of this tree
    for( var value in allChildEventsMap.values) {
        if( value.e.eventData.kind == 1 &&  value.e.eventData.eTagsRest.isEmpty) {  // if its a parent
            topLevelTrees.add(value);
        }
    }

    // add tempWithoutParent to topLevelTrees too

    if(gDebug != 0) print("number of events without parent in fromEvents = ${tempWithoutParent.length}");
    return Tree( events[0], topLevelTrees, allChildEventsMap, tempWithoutParent); // TODO remove events[0]
  } // end fromEvents()

  /*
   * @insertEvents inserts the given new events into the tree, and returns the id the ones actually inserted
   */
  List<String> insertEvents(List<Event> newEvents) {

    List<String> newEventsId = [];

    // add the event to the Tree
    newEvents.forEach((newEvent) { 
      // don't process if the event is already present in the map
      // this condition also excludes any duplicate events sent as newEvents
      if( allChildEventsMap[newEvent.eventData.id] != null) {
        return;
      }

      // handle reaction events and return
      if( newEvent.eventData.kind == 7) {
        String reactedTo = processReaction(newEvent);
        
        if( reactedTo != "") {
          newEventsId.add(newEvent.eventData.id);
          if(gDebug > 0) print("got a new reaction by: ${newEvent.eventData.id} to $reactedTo");
        } else {
          return;
        }
      }
      // only kind 1 events are added to map, return otherwise
      if( newEvent.eventData.kind != 1 && newEvent.eventData.kind != 7) {
        return;
      }
      allChildEventsMap[newEvent.eventData.id] = Tree(newEvent, [], {}, []); 
      newEventsId.add(newEvent.eventData.id);
    });

    

    //print("In insertEvents num eventsId: ${newEventsId.length}");
    // now go over the newly inserted event, and then find its parent, or if its a top tree
    newEventsId.forEach((newId) {
      Tree? newTree = allChildEventsMap[newId]; // this should return true because we just inserted this event in the allEvents in block above
      // in case the event is already present in the current collection of events (main Tree)
      if( newTree != null) {
        // now kind 7 events are also returned and are not added to the tree structure itself
        if( newTree.e.eventData.kind == 7) {
          return;
        }

        // kind 1 events are added to the tree structure
        if( newTree.e.eventData.eTagsRest.isEmpty) {
            // if its a is a new parent event, then add it to the main top parents ( this.children)
            children.add(newTree);
        } else {
            // if it has a parent , then add the newTree as the parent's child
            String parentId = newTree.e.eventData.getParent();
            allChildEventsMap[parentId]?.addChildNode(newTree);
        }
      }
    });

    return newEventsId;
  }

  int printTree(int depth, bool onlyPrintChildren, var newerThan) {

    if( e.eventData.kind != 1) {
      return 0; // for kind 7 event or any other
    }

    int numPrinted = 0;
    children.sort(ascendingTimeTree);
    if( !onlyPrintChildren) {
      e.printEvent(depth);
      numPrinted++;
    } else {
      depth = depth - 1;
    }

    bool leftShifted = false;
    for( int i = 0; i < children.length; i++) {
      if(!onlyPrintChildren) {
        stdout.write("\n");  
        printDepth(depth+1);
        stdout.write("|\n");
      } else {

        DateTime dTime = DateTime.fromMillisecondsSinceEpoch(children[i].e.eventData.createdAt *1000);
        //print("comparing $newerThan with $dTime");
        if( dTime.compareTo(newerThan) < 0) {
          continue;
        }
        stdout.write("\n");  
        printDepth(depth+1);
        stdout.write("\n\n\n");
      }

      // if the thread becomes too 'deep' then reset its depth, so that its 
      // children will not be displayed too much on the right, but are shifted
      // left by about <leftShiftThreadsBy> places
      if( depth > maxDepthAllowed) {
        depth = maxDepthAllowed - leftShiftThreadsBy;
        printDepth(depth+1);
        stdout.write("<${getNumDashes((leftShiftThreadsBy + 1) * gSpacesPerDepth - 1)}+\n");        
        leftShifted = true;
      }

      numPrinted += children[i].printTree(depth+1, false, newerThan);
    }

    if( leftShifted) {
      stdout.write("\n");
      printDepth(depth+1);
      print(">");
    }

    if( onlyPrintChildren) {
      print("\nTotal posts/replies printed: $numPrinted for last $gNumLastDays days");
    }


    return numPrinted;
  }

  /*
   * @printNotifications Add the given events to the Tree, and print the events as notifications
   *                     It should be ensured that these are only kind 1 events
   */
  void printNotifications(List<String> newEventsId) {

    // remove duplicate
    Set temp = {};
    newEventsId.retainWhere((event) => temp.add(newEventsId));
    
    stdout.write("\n---------------------------------------\nNotifications: ");
    if( newEventsId.isEmpty) {
      stdout.write("No new replies/posts.\nTotal posts: ${count()}\n\n");
      return;
    }
    // TODO call count() less
    stdout.write("Number of new replies/posts = ${newEventsId.length}\nTotal posts: ${count()}\n");
    stdout.write("\nHere are the threads with new replies or new likes: \n\n");


    List<Tree> topTrees = []; // collect all top tress to display in this list. only unique tress will be displayed

    newEventsId.forEach((eventID) { 
      // ignore if not in Tree. Should ideally not happen. TODO write warning otherwise
      if( allChildEventsMap[eventID] == null) {
        return;
      }

      Tree ?t = allChildEventsMap[eventID];
      if( t != null) {
        if( t.e.eventData.kind == 1 ) {
          t.e.eventData.isNotification = true;
          Tree topTree = getTopTree(t);
          topTrees.add(topTree);
        } else {
          //t.e.eventData.newLikes = ;
          Event event = t.e;
          if(gDebug >= 0) ("Got notification of type 7");
          String reactorId  = event.eventData.pubkey;
          String comment    = event.eventData.content;
          int    lastEIndex = event.eventData.eTagsRest.length - 1;
          String reactedTo  = event.eventData.eTagsRest[lastEIndex];
          Event? reactedToEvent = allChildEventsMap[reactedTo]?.e;
          if( reactedToEvent != null) {
            Tree? reactedToTree = allChildEventsMap[reactedTo];
            if( reactedToTree != null) {
              reactedToTree.e.eventData.newLikes.add( reactorId);
              Tree topTree = getTopTree(reactedToTree);
              topTrees.add(topTree);
            }
          }
        }
      }
    });

    // remove identidal entries
    // remove duplicate events
    Set ids = {};
    topTrees.retainWhere((t) => ids.add(t.e.eventData.id));
    
    topTrees.forEach( (t) { t.printTree(0, false, 0); });
    print("\n");

  }

  // Write the tree's events to file as one event's json per line
  Future<void> writeEventsToFile(String filename) async {
    //print("opening $filename to write to");
    try {
      final File file         = File(filename);
      int        eventCounter = 0;
      String     nLinesStr    = "";

      const int  numLinesTogether = 200;
      int        linesWritten = 0;
      for( var k in allChildEventsMap.keys) {
        Tree? t = allChildEventsMap[k];
        if( t != null) {
          String line = "${t.e.originalJson}\n";
          nLinesStr += line;
          eventCounter++;    
        }

        if( eventCounter % numLinesTogether == 0) {
          await  file.writeAsString(nLinesStr, mode: FileMode.append).then( (file) => file);
          nLinesStr = "";
          linesWritten += numLinesTogether;
        }
      }

      if(  eventCounter > linesWritten) {
        await  file.writeAsString(nLinesStr, mode: FileMode.append).then( (file) => file);
        nLinesStr = "";
      }

      int len = await file.length();
    } on Exception catch (e) {
      print("Could not open file $filename.");
    }        
    return;
  }

  /*
   * @getTagsFromEvent Searches for all events, and creates a json of e-tag type which can be sent with event
   *                   Also adds 'client' tag with application name.
   * @parameter replyToId First few letters of an event id for which reply is being made
   */
  String getTagStr(String replyToId, String clientName) {
    String strTags = "";

    if( replyToId.isEmpty) {
      strTags += '["client","$clientName"]' ;
      return strTags;
    }

    if( clientName.isEmpty) {
      clientName = "nostr_console";
    }

    // find the latest event with the given id
    int latestEventTime = 0;
    String latestEventId = "";
    for(  String k in allChildEventsMap.keys) {
      if( k.substring(0, replyToId.length) == replyToId) {
        if( ( allChildEventsMap[k]?.e.eventData.createdAt ?? 0) > latestEventTime ) {
          latestEventTime = allChildEventsMap[k]?.e.eventData.createdAt ?? 0;
          latestEventId = k;
        }
      }
    }
    
    if( latestEventId.isEmpty) {
      // search for it in the dummy event id's

    }

    //print("latestEventId = $latestEventId");
    if( latestEventId.isNotEmpty) {
      strTags =  '["e","$latestEventId"]';
    } 

    
    if( strTags != "") {
      strTags += ",";
    }

    strTags += '["client","$clientName"]' ;
    
    //print(strTags);
    return strTags;
  }
 
  int count() {
    int totalCount = 0;
    // ignore dummy events
    if(e.eventData.pubkey != gDummyAccountPubkey) {
      totalCount = 1;
    }

    for(int i = 0; i < children.length; i++) {
      totalCount += children[i].count(); // then add all the children
    }
    return totalCount;
  }

  void addChild(Event child) {
    Tree node;
    node = Tree(child, [], {}, []);
    children.add(node);
  }

  void addChildNode(Tree node) {
    children.add(node);
  }

  Tree getTopTree(Tree t) {

    while( true) {
      Tree? parent =  allChildEventsMap[ t.e.eventData.getParent()];
      if( parent != null) {
        t = parent;
      } else {
        break;
      }
    }
    return t;
  }
}

int ascendingTimeTree(Tree a, Tree b) {
  if(a.e.eventData.createdAt < b.e.eventData.createdAt) {
    return -1;
  } else {
    if( a.e.eventData.createdAt == b.e.eventData.createdAt) {
      return 0;
    }
  }
  return 1;
}

String processReaction(Event event) {

  if( event.eventData.kind == 7 && event.eventData.eTagsRest.isNotEmpty) {
    if(gDebug > 1) ("Got event of type 7");
    String reactorId  = event.eventData.pubkey;
    String comment    = event.eventData.content;
    int    lastEIndex = event.eventData.eTagsRest.length - 1;
    String reactedTo  = event.eventData.eTagsRest[lastEIndex];
    if( gReactions.containsKey(reactedTo)) {
      List<String> temp = [reactorId, comment];
      gReactions[reactedTo]?.add(temp);
    } else {
      List<List<String>> newReactorList = [];
      List<String> temp = [reactorId, comment];
      newReactorList.add(temp);
      gReactions[reactedTo] = newReactorList;
    }
    return reactedTo;
  }
  return "";
}

void processReactions(List<Event> events) {

  for (Event event in events) {
    processReaction(event);
  }
  return;
}

/*
 * @function getTree Creates a Tree out of these received List of events. 
 */
Tree getTree(List<Event> events) {
    if( events.isEmpty) {
      print("Warning: In printEventsAsTree: events length = 0");
      return Tree(Event("","",EventData("non","", 0, 0, "", [], [], [], [[]], {}), [""], "[json]"), [], {}, []);
    }

    // populate the global with display names which can be later used by Event print
    events.forEach( (x) => processKind0Event(x));

    // process NIP 25, or event reactions by adding them to a global map
    processReactions(events);

    for(var reactedTo in gReactions.keys) {
      //print("Got a reaction for $reactedTo. Total number of reactions = ${gReactions[reactedTo]?.length}");
    }

    // remove all events other than kind 1, 7 and 3 ( posts)
    events.removeWhere( (item) => item.eventData.kind != 1 && item.eventData.kind != 7 && item.eventData.kind != 3);  

    // remove bot events
    events.removeWhere( (item) => gBots.contains(item.eventData.pubkey));

    // remove duplicate events
    Set ids = {};
    events.retainWhere((x) => ids.add(x.eventData.id));

    // create tree from events
    Tree node = Tree.fromEvents(events);

    if(gDebug != 0) print("total number of events in main tree = ${node.count()}");
    return node;
}
