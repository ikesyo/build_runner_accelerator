import 'package:json_annotation/json_annotation.dart';

part 'model_022.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model022 {
  const Model022({required this.id, required this.value});

  final int id;
  final String value;

  factory Model022.fromJson(Map<String, dynamic> json) =>
      _$Model022FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model022ToJson(this);
}
