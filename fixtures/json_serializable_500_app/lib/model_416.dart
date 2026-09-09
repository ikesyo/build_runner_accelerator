import 'package:json_annotation/json_annotation.dart';

part 'model_416.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model416 {
  const Model416({required this.id, required this.value});

  final int id;
  final String value;

  factory Model416.fromJson(Map<String, dynamic> json) =>
      _$Model416FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model416ToJson(this);
}
