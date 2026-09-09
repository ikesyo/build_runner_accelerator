import 'package:json_annotation/json_annotation.dart';

part 'model_289.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model289 {
  const Model289({required this.id, required this.value});

  final int id;
  final String value;

  factory Model289.fromJson(Map<String, dynamic> json) =>
      _$Model289FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model289ToJson(this);
}
