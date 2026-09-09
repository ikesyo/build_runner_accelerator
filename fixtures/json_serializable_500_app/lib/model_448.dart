import 'package:json_annotation/json_annotation.dart';

part 'model_448.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model448 {
  const Model448({required this.id, required this.value});

  final int id;
  final String value;

  factory Model448.fromJson(Map<String, dynamic> json) =>
      _$Model448FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model448ToJson(this);
}
