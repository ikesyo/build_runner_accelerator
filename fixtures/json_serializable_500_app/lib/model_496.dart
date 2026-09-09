import 'package:json_annotation/json_annotation.dart';

part 'model_496.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model496 {
  const Model496({required this.id, required this.value});

  final int id;
  final String value;

  factory Model496.fromJson(Map<String, dynamic> json) =>
      _$Model496FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model496ToJson(this);
}
