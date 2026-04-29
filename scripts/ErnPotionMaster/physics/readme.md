# Pachinko Physics

This is the minimum viable product when it comes to "physics" for pachinko games.

There will be a function called "advanceSimulation(dt)", where dt is the time delta to advance the simulation by.

There will be a function called "addBall(id, position, velocity, mass, elasticity)" which will spawn the Ball into the physics engine. It is an error to invoke this function inside "advanceSimulation(dt)".

Similarly, there will be a function to add a pin: "addPin(id, position, elasticity)".

## Balls
We have 0 or more Balls.
Balls are always circles.
Balls are always subject to gravity.
Balls have mass and velocity.
Balls have elasticity.
Balls can collide with other Balls, Pins, and Edges.
Balls will bounce when they collide, as determined by the Ball's elasticity and the elasticity of the object they collided with.

## Pins
We have 0 or more Pins.
Pins are always circles.
Pins are frozen in place, so gravity, mass, and velocity are not relevant.
Pins have elasticity.
Pins don't collide with anything but Balls.
If a Ball hits a Pin, we should invoke a callback with the Ball ID and the Pin ID.

## Edges
The physics area is constrained within a rectangle.
The edges of that rectangle are Edges.
If a Ball hits an Edge, it will perfectly reflect back into the play area.
If a Ball hits an Edge, we should invoke a callback with the Ball ID and the Pin ID.
