import 'package:json_annotation/json_annotation.dart';

part 'model_439.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model439 {
  const Model439({required this.id, required this.value});

  final int id;
  final String value;

  factory Model439.fromJson(Map<String, dynamic> json) =>
      _$Model439FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model439ToJson(this);
}
