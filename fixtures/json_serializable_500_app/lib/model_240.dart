import 'package:json_annotation/json_annotation.dart';

part 'model_240.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model240 {
  const Model240({required this.id, required this.value});

  final int id;
  final String value;

  factory Model240.fromJson(Map<String, dynamic> json) =>
      _$Model240FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model240ToJson(this);
}
