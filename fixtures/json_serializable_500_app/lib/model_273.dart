import 'package:json_annotation/json_annotation.dart';

part 'model_273.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model273 {
  const Model273({required this.id, required this.value});

  final int id;
  final String value;

  factory Model273.fromJson(Map<String, dynamic> json) =>
      _$Model273FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model273ToJson(this);
}
