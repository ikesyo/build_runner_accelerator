import 'package:json_annotation/json_annotation.dart';

part 'model_360.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model360 {
  const Model360({required this.id, required this.value});

  final int id;
  final String value;

  factory Model360.fromJson(Map<String, dynamic> json) =>
      _$Model360FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model360ToJson(this);
}
